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
    /// OpenCode, which reads its global config only at startup. The
    /// restart counter resets so this never reads as a crash.
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

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        // --port 0: the OS assigns a free port, printed on stdout. No fixed
        // port means no collision with the user's own `opencode serve`.
        p.arguments = ["serve", "--port", "0"]
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
            // "opencode server listening on http://127.0.0.1:PORT"
            if let range = buffer.range(of: #"listening on http://127\.0\.0\.1:(\d+)"#, options: .regularExpression) {
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
                Task { @MainActor [weak self] in self?.confirm(port: port) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.exited() }
        }
        do {
            try p.run()
            process = p
            remember(p.processIdentifier)
            logger.notice("launched \(binary, privacy: .public)")
        } catch {
            state = .failed("Couldn't start OpenCode: \(error.localizedDescription)")
        }
    }

    /// The port is known; prove the server actually answers before calling
    /// it running, and learn which API generation it speaks. The health
    /// check is cheap and carries the version the capability handshake
    /// wants anyway.
    private func confirm(port: Int) {
        Task { @MainActor in
            for attempt in 0 ..< 20 {
                if let probe = await OpenCodeAdapter.probe(port: port, password: password) {
                    api = probe.api
                    state = .running(port: port, version: probe.version)
                    restartAttempts = 0
                    logger.notice("opencode \(probe.version, privacy: .public) (\(probe.api.rawValue, privacy: .public) API) on port \(port)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
            state = .failed("OpenCode started but never became healthy.")
            process?.terminate()
        }
    }

    private func exited() {
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
            guard !stopping else { return }
            launch()
        }
    }
}
