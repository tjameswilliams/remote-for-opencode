import Foundation
import OSLog
import RemoteKit

/// The companion's MCP tools, served to the Mac's own `opencode serve`
/// over loopback (RemoteKit's McpHTTPListener does the HTTP; the registry
/// provides the tools, the port, and the token the config entry names).
@MainActor
final class ToolServer {
    private let logger = Logger(subsystem: "com.timwilliams.opencodego", category: "tools")
    private let registry: McpRegistry
    private var listener: McpHTTPListener?

    init(registry: McpRegistry) {
        self.registry = registry
    }

    func start() {
        guard listener == nil else { return }
        let listener = McpHTTPListener(
            server: registry.makeToolServer(), port: McpRegistry.toolPort,
            path: McpRegistry.toolPath, token: registry.token
        )
        listener.onState = { [logger] state in
            switch state {
            case .ready:
                logger.notice("serving management tools on \(McpRegistry.toolPort)")
            case let .failed(reason):
                // Another copy of the app holds the port: the same
                // situation RemoteServer reports for 8766, and the
                // management tools simply reach that copy instead.
                logger.error("tool server failed: \(reason, privacy: .public)")
            case .idle:
                break
            }
        }
        listener.onRefused = { [logger] reason in
            logger.error("tool call refused: \(reason, privacy: .public)")
        }
        do {
            try listener.start()
            self.listener = listener
        } catch {
            logger.error("tool server setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.stop()
        listener = nil
    }
}
