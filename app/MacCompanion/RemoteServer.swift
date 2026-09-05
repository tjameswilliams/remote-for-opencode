import RemoteKit
import Combine
import CryptoKit
import Foundation
import Network
import OSLog

/// Serves protocol v1 to the paired phone over two paths at once: TCP
/// advertised on the LAN via Bonjour, and the punched UDP path that works
/// from anywhere (RemoteKit/Transport/Punch.swift). The phone prefers whichever
/// answers, and everything above the transport is identical either way.
/// Structure lifted from Tomte's AgentServer; what each request *does* is
/// opencodego's own, routed through OpenCodeAdapter.
///
/// Every connection must complete the Wire handshake: a challenge answered
/// with an HMAC keyed by the pairing-derived channel key, after which all
/// traffic is sealed. An unpaired Mac refuses everything — neither being on
/// the same Wi-Fi nor knowing the address is an identity.
@MainActor
final class RemoteServer: ObservableObject {
    private let logger = Logger(subsystem: "com.timwilliams.opencodego", category: "server")
    private var listener: NWListener?
    private let punch = PunchListener()
    private var pairingObserver: NSObjectProtocol?
    /// Where the running OpenCode instance is, or nil while it's down —
    /// requests during a restart get an honest transient failure.
    private let adapter: () -> OpenCodeAdapter?
    /// The scheduled task engine; schedule.* requests are its remote face.
    private let scheduler: Scheduler

    init(adapter: @escaping () -> OpenCodeAdapter?, scheduler: Scheduler) {
        self.adapter = adapter
        self.scheduler = scheduler
    }

    /// The user's kill switch: while paused, the Mac neither advertises nor
    /// listens on either path — remotely, the companion doesn't exist.
    @Published private(set) var paused = false
    /// Set when the listener can't take its port — which in practice means
    /// another copy of this app is already running and holding it. Silence
    /// here is the worst outcome: the phone reaches the *other* instance,
    /// and this window looks fine while doing nothing.
    @Published private(set) var conflict = false

    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        if value {
            listener?.cancel()
            listener = nil
            punch.stop()
            logger.notice("remote access paused")
        } else {
            start()
        }
    }

    func start() {
        guard !paused else { return }
        punch.onStream = { [weak self] stream in
            guard let self else { return }
            Connection(stream, adapter: adapter, scheduler: scheduler, logger: logger).start()
        }
        // The punched path needs a pairing to derive its keys from, and
        // PunchListener.start() bails quietly without one — so re-kick it
        // whenever pairing changes, not just at launch. (Tomte re-triggered
        // this from its Devices pane; a menu bar app has no such moment.)
        punch.start()
        if pairingObserver == nil {
            pairingObserver = NotificationCenter.default.addObserver(
                forName: PairingStore.changed, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.paused else { return }
                    self.punch.start()
                }
            }
        }
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(
                using: params,
                on: NWEndpoint.Port(rawValue: Wire.port)!
            )
            listener.service = NWListener.Service(type: Wire.bonjourType)
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                Task { @MainActor in
                    Connection(
                        TCPTransport(conn), adapter: self.adapter,
                        scheduler: self.scheduler, logger: self.logger
                    ).start()
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case let .failed(error):
                    logger.error("listener failed: \(error.localizedDescription)")
                    // POSIX 48 = address in use: another instance owns the
                    // port, so this one is a zombie the phone can't reach.
                    if case let .posix(code) = error, code == .EADDRINUSE {
                        Task { @MainActor in self.conflict = true }
                    }
                case .ready:
                    Task { @MainActor in self.conflict = false }
                default:
                    break
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            logger.notice("serving on \(Wire.port), advertising \(Wire.bonjourType)")
        } catch {
            logger.error("listener setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Bundle {
    /// What this companion calls itself when explaining that it's old.
    static var companionVersion: String {
        let short = main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) build \(build)"
    }
}

/// One accepted connection, over either transport: challenge → auth → sealed
/// request/response, then it closes. Self-retaining until the transport dies.
@MainActor
private final class Connection {
    private let transport: WireTransport
    private let adapter: () -> OpenCodeAdapter?
    private let scheduler: Scheduler
    private let logger: Logger
    private var framer = LineFramer()
    private let serverNonce = Wire.Security.nonce()
    private var channel: Wire.SecureChannel?
    private var retainCycle: Connection?
    private var clientToken: UUID?
    private var peerCompresses = false
    /// A live watch, when this connection asked for one. Tied to the
    /// connection because that is exactly how a client stops watching: it
    /// hangs up.
    private var watchTask: Task<Void, Never>?

    init(
        _ transport: WireTransport,
        adapter: @escaping () -> OpenCodeAdapter?,
        scheduler: Scheduler,
        logger: Logger
    ) {
        self.transport = transport
        self.adapter = adapter
        self.scheduler = scheduler
        self.logger = logger
    }

    func start() {
        retainCycle = self
        transport.onBytes = { [weak self] data in
            guard let self else { return }
            for frame in framer.push(data) { handle(frame) }
        }
        transport.onClosed = { [weak self] _ in
            guard let self else { return }
            watchTask?.cancel()
            watchTask = nil
            if let token = clientToken {
                clientToken = nil
                ConnectedClients.shared.noteDisconnected(token)
            }
            retainCycle = nil
        }
        transport.start()
        var challenge = Wire.Event(kind: "challenge")
        challenge.text = serverNonce
        writePlain(challenge)
    }

    private func handle(_ frame: Data) {
        guard let channel else {
            authenticate(frame)
            return
        }
        guard let opened = channel.open(frame),
              let plaintext = Wire.Squeeze.unpack(opened),
              let request = try? JSONDecoder().decode(Wire.Request.self, from: plaintext)
        else {
            logger.error("dropping connection: undecryptable or malformed frame")
            transport.close()
            return
        }
        serve(request)
    }

    // MARK: - Handshake

    private func authenticate(_ frame: Data) {
        guard let auth = try? JSONDecoder().decode(Wire.Auth.self, from: frame),
              auth.kind == "auth"
        else {
            refuse("Expected authentication.")
            return
        }
        // Key possession is identity: the tag is tried against every trust
        // this Mac holds — its own in-process loopback key first, then each
        // paired peer's channel key. Whichever verifies says who this is;
        // nothing on the wire claims anything.
        var candidates: [(key: SymmetricKey, loopback: Bool)] = [(LoopbackTrust.key, true)]
        for peer in PairingStore.peers() {
            if let channelKey = try? PairingStore.channelKey(for: peer) {
                candidates.append((channelKey, false))
            }
        }
        guard let matched = candidates.first(where: {
            Wire.Security.verify(
                tag: auth.tag, channelKey: $0.key,
                serverNonce: serverNonce, clientNonce: auth.nonce, name: auth.name
            )
        }) else {
            if PairingStore.peers().isEmpty {
                refuse("This Mac isn't paired with a device yet. Open Devices in the Mac menu bar app to pair.")
            } else {
                logger.error("auth failed for '\(auth.name, privacy: .public)'")
                refuse("This device isn't paired with this Mac.")
            }
            return
        }
        let sessionKey = Wire.Security.sessionKey(
            channelKey: matched.key, serverNonce: serverNonce, clientNonce: auth.nonce
        )
        channel = Wire.SecureChannel(key: sessionKey)
        peerCompresses = auth.compress == true
        clientToken = ConnectedClients.shared.noteAuthenticated(
            name: auth.name, loopback: matched.loopback
        )
        logger.notice("authenticated '\(auth.name, privacy: .public)'\(matched.loopback ? " (loopback)" : "")")
        Task { @MainActor in
            var ready = Wire.Event(kind: "ready")
            ready.compress = true
            ready.capabilities = try? await self.adapter()?.capabilities()
            self.write(ready)
        }
    }

    private func refuse(_ message: String) {
        var e = Wire.Event(kind: "failed")
        e.text = message
        writePlain(e)
        writePlain(Wire.Event(kind: "done"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [transport] in transport.close() }
    }

    // MARK: - Requests

    private func serve(_ request: Wire.Request) {
        // Schedules live in the companion, not in OpenCode, so editing them
        // must work even while OpenCode is down or restarting.
        if request.kind.hasPrefix("schedule.") {
            serveSchedule(request)
            return
        }
        guard let adapter = adapter() else {
            var e = Wire.Event(kind: "failed")
            e.text = "OpenCode is starting on your Mac — try again in a moment."
            e.transient = true
            write(e)
            write(Wire.Event(kind: "done"))
            return
        }
        switch request.kind {
        case "status":
            answer { var e = Wire.Event(kind: "status")
                     e.capabilities = try await adapter.capabilities()
                     return [e] }
        case "projects":
            answer { [try await Self.projectsEvent(adapter: adapter)] }
        case "project.add":
            answer {
                guard let path = request.project else { return [] }
                try ProjectFolders.add(path)
                return [try await Self.projectsEvent(adapter: adapter)]
            }
        case "project.remove":
            answer {
                guard let path = request.project else { return [] }
                ProjectFolders.remove(path)
                return [try await Self.projectsEvent(adapter: adapter)]
            }
        case "sessions":
            answer { var e = Wire.Event(kind: "sessions")
                     // 100, not the adapter's default 20: clients group
                     // sessions under projects now, and 20 recents would
                     // starve every project but the busiest one.
                     e.sessions = try await adapter.sessions(limit: 100, search: request.search)
                     return [e] }
        case "agents":
            answer {
                var e = Wire.Event(kind: "agents")
                e.agents = try await adapter.agents()
                return [e]
            }
        case "changes":
            answer {
                guard let directory = request.project else { return [] }
                var e = Wire.Event(kind: "changes")
                e.changes = try await adapter.workingChanges(
                    directory: directory, mode: request.mode ?? "git"
                )
                return [e]
            }
        case "session.delete":
            answer {
                guard let session = request.session, let directory = request.project
                else { return [] }
                try await adapter.deleteSession(session, directory: directory)
                return []
            }
        case "session.rename":
            answer {
                guard let session = request.session, let directory = request.project,
                      let title = request.title
                else { return [] }
                try await adapter.renameSession(session, directory: directory, title: title)
                return []
            }
        case "commands":
            answer {
                var e = Wire.Event(kind: "commands")
                e.commands = try await adapter.commands()
                return [e]
            }
        case "models":
            answer {
                let (models, defaultID) = try await adapter.models()
                var e = Wire.Event(kind: "models")
                e.models = models
                e.defaultModel = defaultID
                return [e]
            }
        case "mcp":
            answer {
                guard let directory = request.project else { return [] }
                var e = Wire.Event(kind: "mcp")
                e.mcp = try await adapter.mcpServers(
                    directory: directory, sessionID: request.session
                )
                return [e]
            }
        case "prompt":
            servePrompt(request, adapter: adapter)
        case "watch":
            // A subscription, not an answer: relay the session's live
            // events until the client hangs up. No `done` is ever sent on
            // success — a watch has no natural end.
            guard let session = request.session, let directory = request.project else {
                write(Wire.Event(kind: "done"))
                return
            }
            watchTask?.cancel()
            let provider = self.adapter
            watchTask = Task { @MainActor [weak self] in
                await TurnRunner.observe(
                    sessionID: session, directory: directory, adapter: provider
                ) { [weak self] event in
                    self?.write(event)
                }
            }
        case "resume":
            serveResume(request)
        case "permission":
            servePermissionReply(request, adapter: adapter)
        case "pending":
            answer {
                guard let directory = request.project else { return [] }
                var e = Wire.Event(kind: "pending")
                e.permissions = try await adapter.pendingPermissions(directory: directory)
                e.questions = try await adapter.pendingQuestions(directory: directory)
                return [e]
            }
        case "question":
            answer {
                guard let id = request.questionID, let directory = request.project,
                      let answers = request.answers
                else { return [] }
                try await adapter.replyQuestion(id: id, directory: directory, answers: answers)
                return []
            }
        case "abort":
            answer {
                guard let session = request.session, let directory = request.project else { return [] }
                try await adapter.abort(sessionID: session, directory: directory)
                return []
            }
        case "transcript":
            answer {
                guard let session = request.session, let directory = request.project else { return [] }
                // One fetch for everything below: the message list is the
                // whole thread, and a long one is megabytes.
                let messages = try await adapter.messages(sessionID: session, directory: directory)
                var parts = adapter.transcript(in: messages)
                var events: [Wire.Event] = []
                if request.newestFirst == true {
                    // Tail first, so the client can paint the screen the
                    // user actually lands on while the rest is still in
                    // flight. The header is what tells it the order; an
                    // older client never asks and never sees one.
                    var header = Wire.Event(kind: "transcript")
                    header.newestFirst = true
                    header.count = parts.count
                    header.session = session
                    events.append(header)
                    parts.reverse()
                }
                for part in parts {
                    var e = Wire.Event(kind: "part")
                    e.part = part
                    e.session = session
                    events.append(e)
                }
                var diff = Wire.Event(kind: "diff")
                diff.diffs = adapter.turnDiffs(in: messages)
                diff.session = session
                events.append(diff)
                // The context meter's starting point: without this, an
                // opened session shows nothing until the next turn moves
                // the numbers.
                if let usage = try? await adapter.sessionUsage(
                    in: messages, sessionID: session, directory: directory
                ) {
                    var e = Wire.Event(kind: "usage")
                    e.usage = usage
                    e.session = session
                    events.append(e)
                }
                return events
            }
        default:
            answerUnknown(request.kind)
        }
    }

    /// Almost always a phone newer than the Mac app it's talking to: the
    /// companion is a menu bar app people leave running for weeks, so
    /// "rebuilt but not relaunched" is the normal way to arrive here. Say
    /// that, rather than a bare protocol error.
    private func answerUnknown(_ kind: String) {
        var e = Wire.Event(kind: "failed")
        e.text = """
        The Remote for OpenCode app on this Mac doesn't understand "\(kind)"; \
        it's an older version (\(Bundle.companionVersion)). Quit and \
        reopen Remote for OpenCode on your Mac.
        """
        write(e)
        write(Wire.Event(kind: "done"))
    }

    /// The scheduled task requests. Same server-authoritative shape as the
    /// project list: every operation answers with the complete regenerated
    /// list, so a client's copy is always the Mac's truth, never its own
    /// guess.
    private func serveSchedule(_ request: Wire.Request) {
        let scheduler = scheduler
        switch request.kind {
        case "schedule.list":
            answer { [await Self.schedulesEvent(scheduler)] }
        case "schedule.save":
            answer {
                guard let task = request.task else { return [] }
                _ = try await scheduler.save(task)
                return [await Self.schedulesEvent(scheduler)]
            }
        case "schedule.delete":
            answer {
                guard let id = request.taskID else { return [] }
                _ = await scheduler.delete(id: id)
                return [await Self.schedulesEvent(scheduler)]
            }
        case "schedule.run":
            answer {
                guard let id = request.taskID else { return [] }
                _ = await scheduler.runNow(id: id)
                return [await Self.schedulesEvent(scheduler)]
            }
        default:
            answerUnknown(request.kind)
        }
    }

    @MainActor
    private static func schedulesEvent(_ scheduler: Scheduler) -> Wire.Event {
        var e = Wire.Event(kind: "schedules")
        e.tasks = scheduler.list()
        e.timeZone = scheduler.timeZoneIdentifier
        return e
    }

    /// The whole project launcher in one event: known projects (OpenCode's
    /// history, recency-sorted) first, then folders the user pinned by
    /// hand, then repos discovered on disk that OpenCode has never opened.
    /// The same answer serves "projects" and both folder edits, so a
    /// client's list is always the merged truth, never its own guess.
    private static func projectsEvent(adapter: OpenCodeAdapter) async throws -> Wire.Event {
        var projects = try await adapter.projects()
        var seen = Set(projects.map(\.worktree))
        // Pinned folders outrank discovery: the user said this one matters.
        // Once OpenCode opens one it shows up in `known` and the pin goes
        // quiet, deliberately still stored in case the history is cleared.
        for path in ProjectFolders.all().sorted() where !seen.contains(path) {
            seen.insert(path)
            projects.append(
                Project(id: "folder:\(path)", worktree: path, known: false, added: true)
            )
        }
        let discovered = RepoDiscovery.repos()
            .filter { !seen.contains($0) }
            .sorted()
            .map { path in
                Project(id: "repo:\(path)", worktree: path, known: false)
            }
        projects.append(contentsOf: discovered)
        var e = Wire.Event(kind: "projects")
        e.projects = projects
        return e
    }

    /// The one-shot request shape: compute events, send them, close with
    /// `done`; any error becomes a `failed` the phone can show.
    private func answer(_ work: @escaping () async throws -> [Wire.Event]) {
        Task { @MainActor in
            do {
                for event in try await work() { self.write(event) }
            } catch {
                var e = Wire.Event(kind: "failed")
                e.text = error.localizedDescription
                self.write(e)
            }
            self.write(Wire.Event(kind: "done"))
        }
    }

    /// Hands the turn to `LiveTurns` and then does nothing but relay. The
    /// turn deliberately doesn't belong to this connection: the phone's
    /// socket dies every time iOS suspends the app, and an answer owned by
    /// the socket dies with it.
    private func servePrompt(_ request: Wire.Request, adapter: OpenCodeAdapter) {
        let id = request.turn ?? UUID().uuidString
        LiveTurns.shared.start(id, directory: request.project, sink: self) { emit in
            await TurnRunner.run(request, adapter: adapter, emit: emit)
        }
    }

    /// A phone reconnecting to an answer it lost the socket to.
    private func serveResume(_ request: Wire.Request) {
        guard let id = request.turn else {
            write(Wire.Event(kind: "unknown"))
            return
        }
        guard LiveTurns.shared.resume(id, from: request.from ?? 0, sink: self) else {
            // Not a failure: the question never got here, or its answer aged
            // out. The phone should ask again rather than show an error.
            logger.notice("resume: no such turn")
            write(Wire.Event(kind: "unknown"))
            return
        }
        logger.notice("resumed turn from event \(request.from ?? 0)")
    }

    private func servePermissionReply(_ request: Wire.Request, adapter: OpenCodeAdapter) {
        answer {
            guard let id = request.permissionID, let directory = request.project,
                  let reply = request.reply
            else { return [] }
            try await adapter.replyPermission(
                id: id, directory: directory, reply: reply, message: request.message
            )
            return []
        }
    }

    // MARK: - Writes

    /// Pre-handshake only: the challenge and refusals.
    private func writePlain(_ event: Wire.Event) {
        guard let data = Wire.encode(event) else { return }
        transport.send(data)
    }

    private func write(_ event: Wire.Event) {
        guard let channel,
              let plain = try? JSONEncoder().encode(event)
        else { return }
        let body = peerCompresses ? Wire.Squeeze.pack(plain) : plain
        guard let sealed = channel.seal(body) else { return }
        transport.send(sealed)
    }
}

extension Connection: TurnSink {
    func deliver(_ event: Wire.Event) { write(event) }
}

/// Carries an invocation's failure from its own task back to the event
/// loop. An actor because the two run concurrently by design.
actor InvocationFailure {
    private(set) var error: Error?
    func record(_ error: Error) { self.error = error }
}

/// Records when a turn last made progress, so a watchdog can tell a slow
/// model from a dead one. Reset on every event for the turn's own session.
actor ActivityClock {
    private var last = Date()
    func touch() { last = Date() }
    func idleSeconds() -> TimeInterval { Date().timeIntervalSince(last) }
}

/// A one-shot gate: `wait` returns the moment `open` is called, or when the
/// timeout elapses, whichever comes first, and never blocks again after.
/// Used to hold a prompt until its event subscription has connected, with
/// a ceiling so a stream that never connects can't wedge the turn.
actor AsyncStreamGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !opened else { return }
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func wait(timeout: Duration) async {
        if opened { return }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            await self.open()
        }
        await withCheckedContinuation { continuation in
            if opened {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
        timer.cancel()
    }
}

/// Runs one prompt turn against OpenCode: ensure a session, subscribe to its
/// event stream, fire the prompt, and translate what happens into protocol
/// v1 events until the session goes idle.
/// Thrown by the stall watchdog when a turn makes no progress for the
/// whole window while the event stream is still alive.
struct StallTimeout: Error {}

enum TurnRunner {
    /// How long a turn may make no progress before the watchdog gives up.
    /// Well past a slow first token or a large image's prefill; short
    /// enough that a hung local model surfaces as an error, not a phantom
    /// disconnect.
    static let stallTimeout: TimeInterval = 120

    @MainActor
    static func run(
        _ request: Wire.Request, adapter: OpenCodeAdapter,
        emit: @escaping (Wire.Event) -> Void
    ) async {
        func fail(_ message: String, transient: Bool = false) {
            var e = Wire.Event(kind: "failed")
            e.text = message
            e.transient = transient ? true : nil
            emit(e)
            emit(Wire.Event(kind: "done"))
        }
        // A command turn carries a name and arguments instead of prose; a
        // plain turn carries text. Everything after this point — session,
        // model, streaming, permissions, diffs — is identical, which is the
        // reason commands ride the prompt path rather than getting their own.
        guard let directory = request.project else {
            fail("The prompt was missing its project.")
            return
        }
        guard request.text != nil || request.command != nil else {
            fail("The prompt was empty.")
            return
        }
        do {
            let sessionID: String
            if let existing = request.session {
                sessionID = existing
            } else {
                sessionID = try await adapter.createSession(directory: directory)
            }
            // Tell the phone which session this turn landed in before
            // anything streams — it's what makes "continue this thread
            // later" possible.
            var opened = Wire.Event(kind: "status")
            opened.session = sessionID
            emit(opened)

            // The conversation's MCP switches become the session's rules
            // before anything is invoked. On the session rather than the
            // prompt body because command turns have no tools field, and
            // because the session persisting them is what lets a thread
            // configured here keep its toolset in the TUI.
            if let servers = request.mcp {
                try await adapter.setMcp(
                    sessionID: sessionID, directory: directory, servers: servers
                )
            }

            var providerID = request.providerID
            var modelID = request.modelID
            if providerID == nil || modelID == nil {
                guard let fallback = try await adapter.defaultModel() else {
                    fail("No model is configured in OpenCode on your Mac.")
                    return
                }
                providerID = providerID ?? fallback.providerID
                modelID = modelID ?? fallback.modelID
            }

            // A turn that can't carry its context is worse than one refused
            // outright: the model would answer confidently about a file it
            // never saw.
            let attachments = request.attachments ?? []
            let total = attachments.reduce(0) { $0 + $1.byteCount }
            guard total <= OpenCodeAdapter.attachmentLimit else {
                fail("Those files are too large to send (limit \(OpenCodeAdapter.attachmentLimit >> 20) MB).")
                return
            }

            // Session operations that finish immediately (share, undo)
            // never produce a turn, so waiting for session.idle would hang
            // forever. Answer and be done.
            if let name = request.command,
               let builtin = OpenCodeAdapter.Builtin(rawValue: name), !builtin.streams {
                let note = try await adapter.runBuiltin(
                    builtin, sessionID: sessionID, directory: directory,
                    providerID: providerID, modelID: modelID
                )
                var e = Wire.Event(kind: "part")
                e.part = TurnPart(type: "text", id: UUID().uuidString, text: note ?? "Done.")
                e.session = sessionID
                emit(e)
                emit(Wire.Event(kind: "idle"))
                emit(Wire.Event(kind: "done"))
                return
            }

            // Subscribe before invoking, and wait for the subscription to
            // actually connect. `events()` opens the SSE stream on its own
            // task, so "call it first" is not enough: a prompt whose error
            // is near-instant (an image that won't decode emits
            // `session.error` within a second) can beat the connection and
            // be lost, hanging the turn on an idle that never arrives. The
            // gate has a ceiling so a stream that never connects falls
            // through to the pump's own stream-ended handling rather than
            // blocking here.
            let connected = AsyncStreamGate()
            let events = adapter.events(directory: directory) {
                Task { await connected.open() }
            }
            await connected.wait(timeout: .seconds(5))

            // The two invocations have opposite timing: prompt_async
            // returns at once, while POST /command blocks for the whole
            // command — a `/review` can run for minutes. Awaiting that
            // before consuming events would hold back every token until
            // the command had already finished. So the call runs in its
            // own task and the event loop starts immediately; the task's
            // failure (a 4xx, a dead server) is picked up below.
            let failure = InvocationFailure()
            let invocation = Task {
                do {
                    if let name = request.command,
                       let builtin = OpenCodeAdapter.Builtin(rawValue: name) {
                        // Streams a turn (summarize) — fire it and let the
                        // event loop below carry the result.
                        try await adapter.runBuiltin(
                            builtin, sessionID: sessionID, directory: directory,
                            providerID: providerID, modelID: modelID
                        )
                    } else if let command = request.command {
                        try await adapter.runCommand(
                            sessionID: sessionID, directory: directory, command: command,
                            arguments: request.arguments ?? "",
                            providerID: providerID, modelID: modelID,
                            attachments: attachments, agent: request.agent
                        )
                    } else {
                        try await adapter.promptAsync(
                            sessionID: sessionID, directory: directory,
                            text: request.text ?? "",
                            providerID: providerID!, modelID: modelID!,
                            attachments: attachments, agent: request.agent
                        )
                    }
                } catch {
                    await failure.record(error)
                }
            }
            defer { invocation.cancel() }

            // A stall watchdog runs alongside the pump. If our session
            // makes no progress for the whole window (no token, no status,
            // nothing) while the stream itself stays up on its heartbeat,
            // the model has stopped answering (a local backend that hangs on
            // an image request is the case that prompted this). Left alone
            // the turn would wait forever and read as a dead connection, so
            // it is ended as a retryable failure instead. The window is
            // generous: a slow first token or a long image prefill is not a
            // stall.
            let clock = ActivityClock()
            let end = try await withThrowingTaskGroup(of: PumpEnd.self) { group in
                group.addTask {
                    try await pump(
                        events, sessionID: sessionID, directory: directory, adapter: adapter,
                        failure: failure, stopAtIdle: true,
                        onActivity: { Task { await clock.touch() } }, emit: emit
                    )
                }
                group.addTask {
                    while true {
                        try await Task.sleep(for: .seconds(15))
                        if await clock.idleSeconds() >= Self.stallTimeout {
                            throw StallTimeout()
                        }
                    }
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            switch end {
            case .idle, .failed:
                // Terminal events already emitted inside the pump.
                return
            case .streamEnded:
                // The SSE stream ended without an idle — OpenCode went away.
                // That is a restart, not a verdict; worth retrying.
                fail("Lost OpenCode's event stream on your Mac.", transient: true)
            }
        } catch is StallTimeout {
            fail(
                "The model stopped responding on your Mac. It may not support this input, or the local server is stuck.",
                transient: true
            )
        } catch {
            fail(error.localizedDescription, transient: OpenCodeAdapter.isTransient(error))
        }
    }

    /// Watch a session indefinitely: the same translation as a prompt turn,
    /// with nothing invoked. This is how activity that started somewhere
    /// else — the OpenCode TUI in a terminal, another device — reaches an
    /// open session view. A watch outlives any one SSE subscription
    /// (OpenCode restarts; the thread is still the thread), so it
    /// resubscribes until the connection that asked goes away, which
    /// arrives here as task cancellation.
    @MainActor
    static func observe(
        sessionID: String, directory: String,
        adapter: @escaping () -> OpenCodeAdapter?,
        emit: @escaping (Wire.Event) -> Void
    ) async {
        while !Task.isCancelled {
            // Re-resolved each pass: a restarted OpenCode is a new port.
            if let adapter = adapter() {
                let events = adapter.events(directory: directory)
                _ = try? await pump(
                    events, sessionID: sessionID, directory: directory, adapter: adapter,
                    failure: nil, stopAtIdle: false, emit: emit
                )
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Why the shared event loop returned.
    private enum PumpEnd {
        /// The session went idle and the turn's closing events (diff, idle,
        /// done) are out. Prompt turns only.
        case idle
        /// A terminal failure was already emitted. Prompt turns only.
        case failed
        /// The SSE stream itself ended — OpenCode went away.
        case streamEnded
    }

    /// The one event loop, shared by prompt turns and watches: consume an
    /// instance's SSE feed and translate one session's events to protocol
    /// v1. A prompt turn (`stopAtIdle`) ends at the session's next idle and
    /// checks its invocation for failure; a watch runs until the stream
    /// dies, treating idle as a lap marker rather than a finish line.
    @MainActor
    private static func pump(
        _ events: AsyncThrowingStream<[String: Any], Error>,
        sessionID: String, directory: String, adapter: OpenCodeAdapter,
        failure: InvocationFailure?, stopAtIdle: Bool,
        onActivity: (@Sendable () -> Void)? = nil,
        emit: @escaping (Wire.Event) -> Void
    ) async throws -> PumpEnd {
        func fail(_ message: String, transient: Bool = false) {
            var e = Wire.Event(kind: "failed")
            e.text = message
            e.transient = transient ? true : nil
            emit(e)
            emit(Wire.Event(kind: "done"))
        }

        // Which message each part belongs to, and whose it is. The part
        // events don't carry a role, and the user's own message streams
        // back through the same channel as the agent's — without this,
        // the prompt appears a second time in the transcript as if the
        // agent had said it.
        var roles: [String: String] = [:]
        // Text accumulated per part from the delta stream, and each
        // part's type. Reasoning only ever gets two
        // `message.part.updated` events — one empty at the start and
        // one complete at the end — so without the deltas the thinking
        // block sits blank and then snaps to the finished text.
        // `message.part.delta` is where the tokens actually are.
        var partText: [String: String] = [:]
        var partType: [String: String] = [:]
        // Deltas arrive per token — 125 of them for one DeepSeek
        // thinking block, measured. Each protocol event carries the
        // whole accumulated text, so forwarding every one is quadratic
        // in bytes on a link where bytes are seconds, and LiveTurns
        // buffers all of them for replay. Ten a second still reads as
        // live typing; the flush at idle guarantees nothing is lost.
        var lastEmit: [String: Date] = [:]
        let minimumInterval: TimeInterval = 0.1
        // The context meter as last sent. `message.updated` fires several
        // times per step (creation, each timestamp, the finish), and
        // LiveTurns buffers every event for replay, so usage goes out
        // only when the numbers actually moved, which is once per step:
        // the tokens land with the finish.
        var lastUsage: TurnUsage?
        // The session's accumulated cost, from the session record; the
        // one figure that is meant to grow across steps.
        var sessionCost: Double?
        // Context windows per "provider/model", fetched once per pump on
        // the first usage and cached: the catalog doesn't change under a
        // running turn.
        var contextLimits: [String: Int]?

        func emitPart(_ partID: String, force: Bool) {
            guard let kind = partType[partID],
                  kind == "reasoning" || kind == "text",
                  let text = partText[partID], !text.isEmpty
            else { return }
            if !force, let last = lastEmit[partID],
               Date().timeIntervalSince(last) < minimumInterval { return }
            lastEmit[partID] = Date()
            var e = Wire.Event(kind: "part")
            e.part = TurnPart(type: kind, id: partID, text: text)
            e.session = sessionID
            emit(e)
        }

        for try await event in events {
            // The invocation itself failed — a rejected command name, a
            // model that doesn't exist. No session event will ever say
            // so, because the turn never started.
            if let failure, let error = await failure.error {
                fail(error.localizedDescription, transient: OpenCodeAdapter.isTransient(error))
                return .failed
            }
            let type = event["type"] as? String ?? ""
            let properties = event["properties"] as? [String: Any] ?? [:]
            // Progress on our own session resets the stall watchdog. The
            // instance-wide heartbeat carries no sessionID, so a turn whose
            // model has stopped answering goes quiet here even while the
            // stream stays alive, which is exactly the case to catch.
            if properties["sessionID"] as? String == sessionID { onActivity?() }
            switch type {
            case "message.updated":
                guard let info = properties["info"] as? [String: Any],
                      let id = info["id"] as? String, let role = info["role"] as? String
                else { continue }
                roles[id] = role
                // An assistant step's own token accounting is the context
                // meter: its input covers the whole conversation, so it
                // says how full the model's window is right now, the
                // number that tells a user when to /summarize. (The
                // session record's totals are summed over every step ever
                // run, and would read as millions on a long thread.)
                guard info["sessionID"] as? String == sessionID,
                      var usage = OpenCodeAdapter.usage(from: info)
                else { continue }
                if let providerID = info["providerID"] as? String,
                   let modelID = info["modelID"] as? String {
                    if contextLimits == nil {
                        contextLimits = (try? await adapter.contextLimits()) ?? [:]
                    }
                    usage.contextLimit = contextLimits?["\(providerID)/\(modelID)"]
                }
                usage.cost = sessionCost
                guard usage != lastUsage else { continue }
                lastUsage = usage
                var e = Wire.Event(kind: "usage")
                e.usage = usage
                e.session = sessionID
                emit(e)
            case "session.created", "session.updated":
                // Only the accumulated cost is read off the session record;
                // it rides along on the next usage event.
                if let info = properties["info"] as? [String: Any],
                   info["id"] as? String == sessionID,
                   let cost = info["cost"] as? Double {
                    sessionCost = cost
                }
            case "message.part.updated":
                guard let part = properties["part"] as? [String: Any],
                      part["sessionID"] as? String == sessionID
                else { continue }
                // On a prompt turn the phone already showed what the
                // user typed; echoing it back would render it a second
                // time, full-width, as though the agent had written it.
                // On a watch the words were typed somewhere else — the
                // TUI — and forwarding them is the point.
                if let messageID = part["messageID"] as? String,
                   roles[messageID] == "user" {
                    if stopAtIdle { continue }
                    guard let mapped = OpenCodeAdapter.turnPart(from: part, role: "user")
                    else { continue }
                    var e = Wire.Event(kind: "part")
                    e.part = mapped
                    e.session = sessionID
                    emit(e)
                    continue
                }
                // A snapshot is authoritative — it replaces whatever
                // the deltas had accumulated, and it is how we learn
                // what kind of part this is.
                if let partID = part["id"] as? String {
                    partType[partID] = part["type"] as? String
                    if let text = part["text"] as? String, !text.isEmpty {
                        partText[partID] = text
                    }
                }
                guard let mapped = OpenCodeAdapter.turnPart(from: part, role: "assistant")
                else { continue }
                var e = Wire.Event(kind: "part")
                e.part = mapped
                e.session = sessionID
                emit(e)
            // 1.18 asks with `permission.asked`; 1.16-era servers said
            // `permission.updated`. Same skew note as the adapter.
            case "permission.asked", "permission.updated":
                guard let mapped = OpenCodeAdapter.permission(from: properties),
                      mapped.sessionID == nil || mapped.sessionID == sessionID
                else { continue }
                var e = Wire.Event(kind: "permission")
                e.permission = mapped
                e.session = sessionID
                emit(e)
            case "permission.replied":
                // Watches only: the ask was answered somewhere else
                // (the TUI, another device), so take the card down — a
                // bare permission event with no payload is the clear.
                // Prompt turns skip this; their replies come from the
                // client that is showing the card.
                guard !stopAtIdle,
                      properties["sessionID"] as? String ?? sessionID == sessionID
                else { continue }
                var e = Wire.Event(kind: "permission")
                e.session = sessionID
                emit(e)
            case "message.part.delta":
                // `{sessionID, messageID, partID, field, delta}` —
                // the actual token stream, for both reasoning and the
                // answer.
                guard properties["sessionID"] as? String == sessionID,
                      properties["field"] as? String == "text",
                      let partID = properties["partID"] as? String,
                      let delta = properties["delta"] as? String
                else { continue }
                if let messageID = properties["messageID"] as? String,
                   roles[messageID] == "user" { continue }
                partText[partID, default: ""] += delta
                // Until a snapshot has told us the kind, hold the text
                // rather than guessing — rendering reasoning as the
                // answer would be worse than a beat of delay.
                emitPart(partID, force: false)
            case "todo.updated":
                // The agent's own plan for the turn, as it evolves —
                // the clearest possible answer to "what is it doing".
                guard properties["sessionID"] as? String == sessionID else { continue }
                let raw = properties["todos"] as? [[String: Any]]
                    ?? properties["todo"] as? [[String: Any]] ?? []
                var e = Wire.Event(kind: "todos")
                e.todos = OpenCodeAdapter.todos(from: raw)
                e.session = sessionID
                emit(e)
            case "question.asked", "question.updated":
                guard let mapped = OpenCodeAdapter.question(from: properties),
                      mapped.sessionID == nil || mapped.sessionID == sessionID
                else { continue }
                var e = Wire.Event(kind: "question")
                e.question = mapped
                e.session = sessionID
                emit(e)
            case "session.error":
                guard properties["sessionID"] as? String == sessionID else { continue }
                // The event's payload is the only place the real reason
                // lives (prompt_async already answered 204); surface it,
                // and classify it so a retry loop can tell a rate limit
                // from a bad model id.
                let (message, transient) = OpenCodeAdapter.sessionError(from: properties)
                if stopAtIdle {
                    fail(message, transient: transient)
                    return .failed
                }
                // A watched turn erred; the thread is still alive, so
                // say so without done and keep watching.
                var e = Wire.Event(kind: "failed")
                e.text = message
                emit(e)
            case "session.idle":
                guard properties["sessionID"] as? String == sessionID else { continue }
                // Whatever the throttle held back, send now — the last
                // tokens of a thought must not be the ones dropped.
                for partID in partText.keys { emitPart(partID, force: true) }
                var diff = Wire.Event(kind: "diff")
                diff.diffs = (try? await adapter.turnDiffs(
                    sessionID: sessionID, directory: directory
                )) ?? []
                diff.session = sessionID
                emit(diff)
                emit(Wire.Event(kind: "idle"))
                if stopAtIdle {
                    emit(Wire.Event(kind: "done"))
                    return .idle
                }
            default:
                continue
            }
        }
        return .streamEnded
    }
}
