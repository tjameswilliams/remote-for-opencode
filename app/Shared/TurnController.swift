import RemoteKit
import SwiftUI

/// One conversation's turn lifecycle, apart from any screen: send, resume,
/// abort, the event loop, and the blocked-on-you state (permissions,
/// questions). The phone's session screen and the desktop workspace both
/// sit on this — the reconnection design (docs/protocol-v1.md) is subtle
/// enough that it must not be forked twice.
///
/// Reconnection is the design center, not an edge case: every event of a
/// turn is counted, and when the socket dies mid-answer the same turn is
/// resumed from that count — the Mac replays what was missed and streams
/// on. See LiveTurns on the Mac side.
@MainActor
final class TurnController: ObservableObject {
    let project: String
    @Published private(set) var session: String?

    /// The transcript as rendered: parts keyed by id so a re-sent snapshot
    /// updates in place instead of duplicating.
    @Published private(set) var rows: [TurnPart] = []
    @Published private(set) var diffs: [FileDiff] = []
    @Published private(set) var todos: [TodoItem] = []
    @Published private(set) var running = false
    /// A cold load is in flight: the thread was opened empty and its
    /// history is still landing. The transcript shows a wait while the
    /// screen is blank (the one time blank means "wait", not "new") and
    /// pins the bottom without animating as each batch arrives.
    @Published private(set) var loading = false
    @Published var error: String?
    @Published var permission: PermissionRequest?
    @Published var question: QuestionRequest?
    /// When the running turn began — the working indicator escalates its
    /// wording against this.
    @Published private(set) var turnStartedAt = Date()
    /// How full the model's context window is, per the last `usage` event.
    /// A session total, so it survives across turns rather than resetting
    /// with the send.
    @Published private(set) var usage: TurnUsage?

    /// The in-flight turn: its client-minted id and how many of its events
    /// arrived — exactly what `resume` needs.
    private var turnID: String?
    private var cursor = 0

    /// The standing watch on this session, when one is open. Separate from
    /// the turn machinery on purpose: a watch has no cursor and no resume —
    /// losing one costs nothing a transcript reload doesn't recover.
    private var watchTask: Task<Void, Never>?

    /// Whether the client is on screen right now. Drives the response to an
    /// interrupted socket: reconnect immediately when visible, wait to be
    /// resumed otherwise. The phone mirrors scenePhase into this; the
    /// desktop is simply always active.
    var active = true

    private let makeLink: () -> CompanionLink

    init(
        project: String,
        session: String?,
        makeLink: @escaping () -> CompanionLink = { CompanionLink() }
    ) {
        self.project = project
        self.session = session
        self.makeLink = makeLink
    }

    /// What to say the agent is doing: the newest part that has an opinion,
    /// falling back to the honest generic while the first tokens are still
    /// in flight.
    var activity: String {
        rows.reversed().compactMap(\.activityLabel).first ?? "Working"
    }

    // MARK: - Turn lifecycle

    /// Sends a prompt. The caller owns its input field and clears it; this
    /// owns everything from the trimmed text onward.
    func send(
        _ text: String,
        attachments: PromptAttachments,
        model: AgentModel?,
        agent: String?,
        knownCommands: [AgentCommand],
        mcp: [String: Bool]? = nil
    ) {
        guard !running else { return }
        // Files alone are a legitimate prompt ("look at this"), but the
        // model does better with a nudge than with nothing at all.
        let files = attachments.wireAttachments()
        guard !text.isEmpty || !files.isEmpty else { return }
        let prompt = text.isEmpty ? "Take a look at the attached file(s)." : text
        error = nil
        diffs = []
        todos = []
        // Name the files in the transcript so the turn reads correctly
        // later, when the thumbnails are long gone.
        let names = attachments.items.map(\.name)
        attachments.clear()
        rows.append(TurnPart(
            type: "user",
            text: names.isEmpty ? prompt : prompt + "\n\n📎 " + names.joined(separator: ", ")
        ))

        var request = Wire.Request(kind: "prompt")
        request.project = project
        request.session = session
        request.attachments = files.isEmpty ? nil : files
        if let slash = SlashInput.command(prompt, known: knownCommands) {
            // The Mac invokes the command by name; OpenCode expands its own
            // template. Nothing here knows what the command actually says.
            request.command = slash.name
            request.arguments = slash.arguments
        } else {
            request.text = prompt
        }
        // Absent means "whatever the Mac would have used" — a deliberate
        // choice the picker offers explicitly.
        request.providerID = model?.providerID
        request.modelID = model?.modelID
        // Absent means OpenCode's own default (build).
        request.agent = agent
        // Absent means "leave the session's tool rules alone".
        request.mcp = mcp
        let id = UUID().uuidString
        request.turn = id
        turnID = id
        cursor = 0
        turnStartedAt = Date()
        running = true
        Task { await consume(makeLink().run(request)) }
    }

    func resume() {
        guard let turnID else { return }
        var request = Wire.Request(kind: "resume")
        request.turn = turnID
        request.from = cursor
        Task { await consume(makeLink().run(request)) }
    }

    /// Stops the agent, not just the stream: the Mac tells OpenCode to
    /// abort the session, and the running turn winds down through its own
    /// idle → done, which is what resets `running` honestly.
    func abort() {
        guard let session else { running = false; turnID = nil; return }
        var request = Wire.Request(kind: "abort")
        request.session = session
        request.project = project
        Task {
            for await event in makeLink().run(request) where event.kind == "failed" {
                error = event.text
            }
        }
    }

    /// One event loop for prompt and resume alike — the Mac replays and
    /// then streams, and replayed events look exactly like live ones.
    private func consume(_ stream: AsyncStream<Wire.Event>) async {
        for await event in stream {
            // `ready` belongs to the connection, not the turn: it is not in
            // the Mac's replay buffer, so it must not advance the cursor.
            if event.kind != "ready" { cursor += 1 }
            switch event.kind {
            case "status":
                if let id = event.session { session = id }
            case "part":
                if let part = event.part { upsert(part) }
            case "permission":
                permission = event.permission
            case "question":
                question = event.question
            case "diff":
                diffs = event.diffs ?? []
            case "todos":
                todos = event.todos ?? []
            case "usage":
                if let usage = event.usage { self.usage = usage }
            case "idle", "done":
                if event.kind == "done" { running = false; turnID = nil }
            case "failed":
                error = event.text
                if event.transient != true { running = false; turnID = nil }
            case "interrupted":
                // Socket lost mid-answer. If we're on screen, reconnect now;
                // otherwise the owner resumes us when it returns.
                if active { resume() }
                return
            case "unknown":
                // The Mac never got the question, or it aged out. Honest
                // reset: the user re-sends, nothing pretends otherwise.
                error = "That answer is gone — ask again."
                running = false
                turnID = nil
            default:
                break
            }
        }
    }

    private func upsert(_ part: TurnPart) {
        if let id = part.id, let index = rows.lastIndex(where: { $0.id == id }) {
            rows[index] = part
        } else {
            rows.append(part)
        }
    }

    // MARK: - Watching

    /// Live updates for activity this client didn't start — a turn driven
    /// from the OpenCode TUI in a terminal, or from another device. Holds
    /// one long-lived `watch` request open; the Mac relays the session's
    /// events as they happen and this folds them into the same rows the
    /// turn stream fills, deduped by part id.
    func watch() {
        guard watchTask == nil, session != nil else { return }
        // Weak throughout: the watch must not keep a dismissed screen's
        // controller alive — deinit's cancel is what ends it, and a strong
        // capture across the long-lived stream would prevent exactly that.
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let session = self?.session, let project = self?.project,
                      let link = self?.makeLink()
                else { break }
                var request = Wire.Request(kind: "watch")
                request.session = session
                request.project = project
                // A healthy watch never completes: `done` only arrives when
                // the Mac declined it (an older companion, no path to the
                // Mac), and asking again would get the same answer.
                var declined = false
                for await event in link.run(request) {
                    guard let self else { return }
                    if event.kind == "done" { declined = true }
                    self.handleWatch(event)
                }
                if declined || Task.isCancelled || self?.active != true { break }
                // The socket died mid-watch (sleep, network change). The
                // thread is still on screen, so pick the watch back up.
                try? await Task.sleep(for: .seconds(2))
            }
            self?.watchTask = nil
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    deinit {
        watchTask?.cancel()
    }

    /// Watch events reuse the turn vocabulary but not its lifecycle: parts
    /// mean the session is busy, idle means it settled, and failures stay
    /// quiet — a watch is an enhancement, and its errors must not paint an
    /// otherwise healthy transcript red.
    private func handleWatch(_ event: Wire.Event) {
        switch event.kind {
        case "part":
            guard let part = event.part else { return }
            // Our own prompt echoes back through the watch while a turn is
            // in flight; the transcript already has it.
            if part.type == "user", turnID != nil { return }
            if !running {
                turnStartedAt = Date()
                running = true
            }
            upsert(part)
        case "todos":
            todos = event.todos ?? []
        case "diff":
            diffs = event.diffs ?? []
        case "usage":
            if let usage = event.usage { self.usage = usage }
        case "permission":
            // Nil payload means the ask was answered somewhere else — the
            // TUI, another device — and the card comes down.
            permission = event.permission
        case "question":
            question = event.question
        case "idle":
            // Our own turn's lifecycle owns `running` while it's in flight.
            if turnID == nil {
                running = false
                permission = nil
                question = nil
            }
        default:
            break
        }
    }

    // MARK: - Approvals

    func answer(_ request: PermissionRequest, reply: String, message: String?) {
        Task {
            // Biometrics stand in front of granting, never of declining.
            if reply != "reject", await !Approver.confirm() { return }
            permission = nil
            var wire = Wire.Request(kind: "permission")
            wire.permissionID = request.id
            wire.project = project
            wire.reply = reply
            wire.message = message
            for await event in makeLink().run(wire) where event.kind == "failed" {
                error = event.text
            }
        }
    }

    func answer(_ request: QuestionRequest, answers: [[String]]) {
        question = nil
        var wire = Wire.Request(kind: "question")
        wire.questionID = request.id
        wire.project = project
        wire.answers = answers
        Task {
            for await event in makeLink().run(wire) where event.kind == "failed" {
                error = event.text
            }
        }
    }

    // MARK: - Continuing an existing session

    /// Loads the thread's history in batches, tail first.
    ///
    /// Parts are never applied one at a time: on a long thread that is
    /// thousands of view updates, each with an animated scroll, and the
    /// user waits a minute watching history crawl past. Instead the Mac
    /// is asked for the parts newest first, the first screen's worth is
    /// painted as soon as it lands, and the rest fills in above it in
    /// doubling batches (see TranscriptLoad). An older Mac ignores the
    /// order request and sends reading order with no header; that case
    /// is collected whole and painted once at the end.
    func loadTranscript() async {
        guard let session else { return }
        var request = Wire.Request(kind: "transcript")
        request.session = session
        request.project = project
        request.newestFirst = true
        loading = rows.isEmpty
        defer { loading = false }
        // Parts in arrival order; `newestFirst` says which way that is.
        var received: [TurnPart] = []
        var newestFirst = false
        func flush() {
            let transcript = newestFirst ? Array(received.reversed()) : received
            let merged = TranscriptLoad.merge(transcript, into: rows)
            // A reload that changes nothing must not disturb the screen.
            if merged != rows { rows = merged }
        }
        for await event in makeLink().run(request) {
            switch event.kind {
            case "transcript":
                newestFirst = event.newestFirst == true
            case "part":
                guard let part = event.part else { break }
                received.append(part)
                if newestFirst, TranscriptLoad.shouldFlush(after: received.count) { flush() }
            case "diff": diffs = event.diffs ?? []
            case "usage": if let usage = event.usage { self.usage = usage }
            case "failed": error = event.text
            default: break
            }
        }
        flush()
    }
}
