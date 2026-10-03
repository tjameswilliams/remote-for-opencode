import Foundation
import Network

/// Serves an `McpToolServer` over loopback HTTP, in the Streamable HTTP
/// transport's simplest form: one JSON-RPC POST, one JSON answer, no
/// server-initiated stream. An MCP client (OpenCode's, via the official
/// SDK) connects to it like any remote server.
///
/// Loopback and a bearer token, both. The listener never binds anything
/// but 127.0.0.1, so nothing off the machine can reach it; the token is
/// the difference between the client the config names and any other
/// local process that finds the port.
@MainActor
public final class McpHTTPListener {
    public enum State: Equatable, Sendable {
        case idle
        case ready
        case failed(String)
    }

    public let server: McpToolServer
    public let port: UInt16
    public let path: String
    public let token: String
    public private(set) var state: State = .idle
    /// Called on every state change, for the host's log.
    public var onState: ((State) -> Void)?
    /// Called for requests refused before reaching the server (bad token,
    /// malformed HTTP), with a short reason.
    public var onRefused: ((String) -> Void)?

    private var listener: NWListener?

    public init(server: McpToolServer, port: UInt16, path: String = "/mcp", token: String) {
        self.server = server
        self.port = port
        self.path = path
        self.token = token
    }

    public func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!
        )
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { @MainActor in
                Connection(connection, listener: self).start()
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case let .failed(error): self.update(.failed(error.localizedDescription))
                case .ready: self.update(.ready)
                case .cancelled: self.update(.idle)
                default: break
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func update(_ state: State) {
        self.state = state
        onState?(state)
    }

    fileprivate func refused(_ reason: String) {
        onRefused?(reason)
    }

    /// One accepted connection: HTTP requests in, answered in order, until
    /// the peer hangs up. Self-retaining until then.
    @MainActor
    private final class Connection {
        private let connection: NWConnection
        private unowned let owner: McpHTTPListener
        private var parser = HTTPRequestParser()
        private var retainCycle: Connection?
        /// Requests on one connection are answered one after another, in
        /// order: a pipelined second request must not overtake the first.
        private var queue: Task<Void, Never>?

        init(_ connection: NWConnection, listener: McpHTTPListener) {
            self.connection = connection
            owner = listener
        }

        func start() {
            retainCycle = self
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    Task { @MainActor in self.retainCycle = nil }
                default:
                    break
                }
            }
            connection.start(queue: .main)
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let data, !data.isEmpty {
                        do {
                            for request in try self.parser.push(data) { self.enqueue(request) }
                        } catch {
                            self.owner.refused("malformed HTTP: \(error)")
                            self.send(HTTPResponse.render(status: 400))
                            self.connection.cancel()
                            return
                        }
                    }
                    if complete || error != nil {
                        self.connection.cancel()
                        return
                    }
                    self.receive()
                }
            }
        }

        private func enqueue(_ request: HTTPRequest) {
            let previous = queue
            queue = Task { @MainActor [weak self] in
                await previous?.value
                guard let self else { return }
                self.send(await self.answer(request))
            }
        }

        private func answer(_ request: HTTPRequest) async -> Data {
            let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
            guard path == owner.path else { return HTTPResponse.render(status: 404) }
            guard request.header("Authorization") == "Bearer \(owner.token)" else {
                owner.refused("bad or missing token")
                return HTTPResponse.render(status: 401)
            }
            switch request.method {
            case "POST":
                guard let body = await owner.server.handle(body: request.body) else {
                    return HTTPResponse.render(status: 202)
                }
                return HTTPResponse.render(
                    status: 200, headers: [("Content-Type", "application/json")], body: body
                )
            case "DELETE":
                // Session teardown in the spec; this server keeps no session.
                return HTTPResponse.render(status: 200)
            default:
                // GET opens the server-to-client stream, which this server
                // doesn't offer; 405 is how the spec says so.
                return HTTPResponse.render(status: 405)
            }
        }

        private func send(_ data: Data) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }
}
