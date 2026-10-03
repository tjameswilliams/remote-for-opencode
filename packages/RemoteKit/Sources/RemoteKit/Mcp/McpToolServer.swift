import Foundation

/// One tool the companion offers a model over MCP: its schema for the
/// catalogue, and the handler that answers a call with text.
public struct McpTool: @unchecked Sendable {
    public var name: String
    public var description: String
    /// A JSON Schema object (`{"type": "object", "properties": …}`).
    public var inputSchema: [String: Any]
    /// Runs the call. Throwing turns into a tool result with `isError`
    /// set, which the model sees as text, not into a protocol failure.
    public var handler: @Sendable ([String: Any]) async throws -> String

    public init(
        name: String, description: String, inputSchema: [String: Any],
        handler: @escaping @Sendable ([String: Any]) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.handler = handler
    }
}

/// A message a tool handler wants the model to read verbatim, as opposed
/// to a Swift error whose description would be the text.
public struct McpToolFailure: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// The Model Context Protocol, server side, reduced to what a tool-only
/// server over Streamable HTTP needs: `initialize`, `ping`, `tools/list`,
/// `tools/call`, and JSON-RPC's error shapes. Everything about transport
/// (HTTP, sessions) lives in the caller; this type turns one request body
/// into one response body.
///
/// Protocol version: whatever the client asked for is echoed back. Every
/// version so far agrees on the four methods used here, and a client
/// refuses a version it doesn't know, so echoing is what keeps an SDK
/// upgrade on OpenCode's side from breaking the handshake.
public final class McpToolServer: @unchecked Sendable {
    public let name: String
    public let version: String
    /// Text OpenCode folds into the system prompt when the server's tools
    /// are visible: what these tools are for, in a sentence or two.
    public let instructions: String?
    public let tools: [McpTool]

    /// What a client that doesn't say gets.
    static let fallbackProtocolVersion = "2025-03-26"

    public init(name: String, version: String, instructions: String? = nil, tools: [McpTool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    /// One POST body in, one body out. Nil means there is nothing to send
    /// back (a notification, or a batch of them): the transport answers
    /// 202 Accepted with no body, as the spec asks.
    public func handle(body: Data) async -> Data? {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: body)
        } catch {
            return Self.encode(Self.error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        if let batch = parsed as? [Any] {
            guard !batch.isEmpty else {
                return Self.encode(Self.error(id: NSNull(), code: -32600, message: "Invalid Request"))
            }
            var responses: [[String: Any]] = []
            for item in batch {
                if let response = await handle(message: item) { responses.append(response) }
            }
            return responses.isEmpty ? nil : Self.encode(responses)
        }
        return await handle(message: parsed).flatMap(Self.encode)
    }

    /// One JSON-RPC message. Nil for a notification (no `id`), which gets
    /// no response by definition.
    public func handle(message: Any) async -> [String: Any]? {
        guard let message = message as? [String: Any],
              message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String
        else {
            return Self.error(id: (message as? [String: Any])?["id"] ?? NSNull(),
                              code: -32600, message: "Invalid Request")
        }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id = message["id"] else {
            // Notifications: initialized, cancelled, progress. Nothing to
            // do for any of them in a stateless tool server.
            return nil
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            var result: [String: Any] = [
                "protocolVersion": requested ?? Self.fallbackProtocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": name, "version": version],
            ]
            if let instructions { result["instructions"] = instructions }
            return Self.result(id: id, result)
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": tools.map { tool in
                ["name": tool.name, "description": tool.description, "inputSchema": tool.inputSchema]
                    as [String: Any]
            }])
        case "tools/call":
            guard let toolName = params["name"] as? String else {
                return Self.error(id: id, code: -32602, message: "Missing tool name")
            }
            guard let tool = tools.first(where: { $0.name == toolName }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(toolName)")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await tool.handler(arguments)
                return Self.result(id: id, Self.content(text, isError: false))
            } catch {
                let text = (error as? McpToolFailure)?.description
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                return Self.result(id: id, Self.content(text, isError: true))
            }
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func content(_ text: String, isError: Bool) -> [String: Any] {
        var result: [String: Any] = ["content": [["type": "text", "text": text]]]
        if isError { result["isError"] = true }
        return result
    }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func encode(_ object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }
}
