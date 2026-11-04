import RemoteKit
import AppKit
import Foundation
import OSLog

/// Owns the `opencode serve` child process. The whole product story is "the
/// user never runs a command", so this finds the binary, starts the server
/// bound to localhost on an OS-assigned port, restarts it when it dies, and
/// reports state the menu bar can show.
///
/// The server is deliberately never exposed to the network — 127.0.0.1 only.
/// The phone reaches it exclusively through RemoteServer's authenticated,
/// encrypted channel; this process is the only trusted gateway.
@MainActor
final class OpenCodeProcess: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        /// Serving on this localhost port.
        case running(port: Int, version: String)
        /// Something the user may need to act on ("OpenCode isn't
        /// installed"), or the last crash while backoff counts down.
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    /// Which generation of OpenCode's API the running server speaks,
    /// probed once it answers. Meaningful only while `running`.
    private(set) var api: OpenCodeAdapter.API = .v1

    /// The password the current child was started with. OpenCode 2 always
    /// requires one (it generates its own when none is given), so the
    /// companion picks a fresh one per launch and is the only holder. A 1.x
    /// server ignores it.
    private(set) var password = OpenCodeProcess.makePassword()

    /// The adapter for the running server, nil while it isn't.
    var adapter: OpenCodeAdapter? {
        guard case let .running(port, _) = state else { return nil }
        return OpenCodeAdapter(port: port, api: api, password: password)
    }

    private static func makePassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private let logger = Logger(subsystem: "com.timwilliams.opencodego", category: "opencode")
    private var process: Process?
    private var restartAttempts = 0
    private var stopping = false
    /// Counts launches. Every callback a child sets up (its port, its
    /// health check, its exit) carries the number it was launched under
    /// and is ignored once a newer launch exists. Without this, a restart's
    /// old child exiting late reads as the new one crashing: it dropped the
    /// new child's handle (orphaning it) and launched a second server.
    private var generation = 0
    /// The generation whose child has printed its listening line. A launch
    /// still missing from here when the startup timeout fires is stuck.
    private var announced = 0
    /// How long a child gets to print its listening line. A first run can
    /// install plugins before it serves, so this is generous; the point is
    /// only that "Starting OpenCode…" can't last forever.
    private static let startupTimeout: Duration = .seconds(60)

    /// Where the homebrew, manual, and bun installs land. `which` isn't
    /// available to a GUI app (no login-shell PATH), so known locations
    /// first, then a login shell as the fallback for exotic setups.
    static func findBinary() -> String? {
        // A developer override, for running the companion against a
        // particular OpenCode (the kept 1.x install, say) without touching
        // the one on PATH:
        //   defaults write com.timwilliams.opencodego.mac OpenCodeBinary ~/.local/bin/opencode-v1
        // `defaults delete … OpenCodeBinary` goes back to the search below.
        if let override = UserDefaults.standard.string(forKey: "OpenCodeBinary"), !override.isEmpty {
            let path = NSString(string: override).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let candidates = [
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            NSString(string: "~/.bun/bin/opencode").expandingTildeInPath,
            NSString(string: "~/.opencode/bin/opencode").expandingTildeInPath,
            // OpenCode 2's npm package also installs itself as `opencode2`,
            // so a side-by-side install still has something to find.
            "/opt/homebrew/bin/opencode2",
            "/usr/local/bin/opencode2",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "command -v opencode"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        try? probe.run()
        probe.waitUntilExit()
        let path = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    func start() {
        reapStalechild()
        guard case .running = state else {
            launch()
            return
        }
    }

    /// A previous companion that crashed (or was stopped from Xcode) leaves
    /// its `opencode serve` child running — children don't die with their
    /// parent. The pidfile remembers who we spawned so the next launch can
    /// clean up, and only ever kills a process that is still ours.
    private static let pidfile = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    // Still the pre-rename directory name: a 1.0 companion that crashed
    // left its pid there, and moving the path would orphan that child on
    // the first post-rename launch.
    )[0].appendingPathComponent("OpenCodeGo/opencode.pid")

    private func reapStalechild() {
        guard let text = try? String(contentsOf: Self.pidfile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        try? FileManager.default.removeItem(at: Self.pidfile)
        // Verify it's still an opencode process before signalling — PIDs
        // get recycled, and killing a stranger is worse than an orphan.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/ps")
        probe.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        probe.standardOutput = pipe
        try? probe.run()
        probe.waitUntilExit()
        let command = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        guard command.contains("opencode") else { return }
        logger.notice("killing orphaned opencode serve (pid \(pid))")
        kill(pid, SIGTERM)
    }

    private func remember(_ pid: Int32) {
        let dir = Self.pidfile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(pid)".write(to: Self.pidfile, atomically: true, encoding: .utf8)
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(at: Self.pidfile)
        state = .stopped
    }

    /// The app is quitting: take the child down with it. Children outlive
    /// their parent, so without this every quit left an `opencode serve`
    /// running until the next launch's pidfile reaper found it (and only
    /// the most recent one at that). Waits a moment for the exit; if the
    /// child is still alive after that, the pidfile is kept so the next
    /// launch can still finish the job.
    func stopForQuit() {
        stopping = true
        guard let process, process.isRunning else {
            try? FileManager.default.removeItem(at: Self.pidfile)
            return
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            logger.error("opencode serve (pid \(process.processIdentifier)) outlived quit; next launch reaps it")
        } else {
            try? FileManager.default.removeItem(at: Self.pidfile)
        }
        self.process = nil
    }

    init() {
        // AppKit's last word before exit, posted on the main thread for
        // Quit, logout and shutdown alike. (A force quit or Xcode's Stop
        // sends no notice; the pidfile covers those.)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForQuit() }
        }
    }

    /// A deliberate stop and fresh launch: how a config change reaches
    /// OpenCode, which reads its global config only at startup, and the
    /// user's way out of a wedged or crash-looping server. Works from any
    /// state, "keeps crashing" and "isn't installed" included (the binary
    /// is searched for again). The restart counter resets so this never
    /// reads as a crash.
    func restart() {
        stop()
        restartAttempts = 0
        launch()
    }

    private func launch() {
        guard let binary = Self.findBinary() else {
            state = .failed("OpenCode isn't installed. Install it with: brew install opencode")
            return
        }
        state = .starting
        stopping = false
        generation += 1
        let launched = generation

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        // --port 0: the OS assigns a free port, printed on stdout. No fixed
        // port means no collision with the user's own `opencode serve`.
        // --hostname pins it to loopback even when the user's config asks
        // for another address (or mDNS, which means 0.0.0.0 on 1.x).
        p.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "0"]
        var env = ProcessInfo.processInfo.environment
        // The CLI shells out to git and friends; a GUI app's PATH lacks
        // their usual homes.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        // OpenCode 2 reads its server password from here; without it, it
        // would mint one we'd have to scrape off stdout.
        password = Self.makePassword()
        env["OPENCODE_PASSWORD"] = password
        env.removeValue(forKey: "OPENCODE_SERVER_PASSWORD")
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        var buffer = ""
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty means EOF: the child is gone. Drop the handler, or it
            // fires again immediately, forever.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            buffer += text
            // What it says before it serves is what explains a stuck start.
            let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { self?.logger.debug("opencode: \(said, privacy: .public)") }
            // "opencode server listening on http://127.0.0.1:PORT" (1.x),
            // "server listening on ..." (2.x). Any host is accepted: the
            // port is what matters, and the health check proves it answers.
            if let range = buffer.range(of: #"listening on https?://\S+:\d+"#, options: .regularExpression) {
                let port = Int(buffer[range].split(separator: ":").last ?? "") ?? 0
                buffer = ""
                // Keep reading for the life of the child. A pipe nobody
                // drains fills at 64 KB, and a process blocked on a write
                // to it (a stack trace, say) hangs rather than crashes,
                // which is the worst way for OpenCode to fail. What it
                // prints is worth the log anyway.
                handle.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        handle.readabilityHandler = nil
                        return
                    }
                    guard let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                    else { return }
                    self?.logger.debug("opencode: \(text, privacy: .public)")
                }
                Task { @MainActor [weak self] in self?.confirm(port: port, launched: launched) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.exited(launched: launched) }
        }
        do {
            try p.run()
            process = p
            remember(p.processIdentifier)
            logger.notice("launched \(binary, privacy: .public)")
        } catch {
            state = .failed("Couldn't start OpenCode: \(error.localizedDescription)")
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.startupTimeout)
            self?.startupTimedOut(launched: launched)
        }
    }

    /// The child is alive but never said where it's listening: hung in its
    /// own startup, or printing something we don't recognize. Stop it and
    /// say so, rather than restarting into the same wall; Restart OpenCode
    /// is the way back once the cause is fixed.
    private func startupTimedOut(launched: Int) {
        guard launched == generation, announced != launched, state == .starting,
              process?.isRunning == true else { return }
        logger.error("opencode printed no listening address within \(Self.startupTimeout); stopping it")
        stop()
        state = .failed("OpenCode didn't finish starting. Run \"opencode serve\" in Terminal to see why.")
    }

    /// The port is known; prove the server actually answers before calling
    /// it running, and learn which API generation it speaks. The health
    /// check is cheap and carries the version the capability handshake
    /// wants anyway.
    private func confirm(port: Int, launched: Int) {
        if launched == generation { announced = launched }
        Task { @MainActor in
            for attempt in 0 ..< 20 {
                guard launched == generation else { return }
                if let probe = await OpenCodeAdapter.probe(port: port, password: password) {
                    api = probe.api
                    state = .running(port: port, version: probe.version)
                    restartAttempts = 0
                    logger.notice("opencode \(probe.version, privacy: .public) (\(probe.api.rawValue, privacy: .public) API) on port \(port)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
            guard launched == generation else { return }
            state = .failed("OpenCode started but never became healthy.")
            process?.terminate()
        }
    }

    private func exited(launched: Int) {
        guard launched == generation else { return }
        process = nil
        guard !stopping else { return }
        restartAttempts += 1
        guard restartAttempts <= 5 else {
            state = .failed("OpenCode keeps crashing — check its logs.")
            return
        }
        let delay = Double(restartAttempts) * 2
        logger.error("opencode exited; restarting in \(Int(delay))s (attempt \(self.restartAttempts))")
        state = .starting
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !stopping, launched == generation else { return }
            launch()
        }
    }
}

/// The user's explicit "Restart OpenCode", from the menu bar, the
/// workspace, or a paired device. Running turns stop with it; the callers
/// warn about that first. Goes through Model Sources and the MCP registry so
/// their "restart to apply" offers clear too: this restart applies them.
@MainActor
enum OpenCodeRestart {
    static func now() {
        ModelSourceStore.shared.restartNow()
        McpRegistry.shared.noteRestarted()
    }

    /// The Mac's own confirmation, asked only when there is something to
    /// lose. Returns once the user has chosen; true means restarted.
    @discardableResult
    static func confirmAndRestart() -> Bool {
        let running = LiveTurns.shared.activeCount
        if running > 0 {
            let alert = NSAlert()
            alert.messageText = "Restart OpenCode?"
            alert.informativeText = running == 1
                ? "A turn is running. Restarting stops it."
                : "\(running) turns are running. Restarting stops them."
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        now()
        return true
    }
}
