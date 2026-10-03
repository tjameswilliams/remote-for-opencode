import Foundation
import Testing

@testable import RemoteKit

/// The companion's own MCP server is what lets the global chat manage the
/// Mac's MCP servers, so the handshake OpenCode's client runs and the
/// HTTP it rides on are worth pinning down without a running OpenCode.
@Suite("MCP tool server")
struct McpToolServerTests {
    private func server() -> McpToolServer {
        McpToolServer(
            name: "remote", version: "1.0", instructions: "Manage things.",
            tools: [
                McpTool(
                    name: "echo", description: "Echoes",
                    inputSchema: ["type": "object", "properties": ["text": ["type": "string"]]]
                ) { args in
                    guard let text = args["text"] as? String else { throw McpToolFailure("no text") }
                    return "echo: \(text)"
                },
            ]
        )
    }

    private func call(_ server: McpToolServer, _ json: String) async throws -> [String: Any] {
        let data = try #require(await server.handle(body: Data(json.utf8)))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("initialize echoes the client's protocol version and advertises tools")
    func initialize() async throws {
        let response = try await call(server(), """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"opencode","version":"1.18.15"}}}
        """)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-11-25")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "remote")
        #expect(result["instructions"] as? String == "Manage things.")
        #expect(response["id"] as? Int == 1)
    }

    @Test("a client that names no version gets the fallback")
    func initializeFallback() async throws {
        let response = try await call(server(), """
        {"jsonrpc":"2.0","id":"a","method":"initialize","params":{}}
        """)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == McpToolServer.fallbackProtocolVersion)
        #expect(response["id"] as? String == "a")
    }

    @Test("notifications get no response")
    func notification() async throws {
        let data = await server().handle(body: Data("""
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        """.utf8))
        #expect(data == nil)
    }

    @Test("tools/list carries the schema")
    func list() async throws {
        let response = try await call(server(), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try #require((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "echo")
        #expect((tools[0]["inputSchema"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test("tools/call returns text content, and a thrown failure is an isError result")
    func callTool() async throws {
        let ok = try await call(server(), """
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}
        """)
        let content = try #require((ok["result"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "echo: hi")
        #expect((ok["result"] as? [String: Any])?["isError"] == nil)

        let failed = try await call(server(), """
        {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{}}}
        """)
        let result = try #require(failed["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect((result["content"] as? [[String: Any]])?.first?["text"] as? String == "no text")
    }

    @Test("unknown tools and methods are JSON-RPC errors")
    func errors() async throws {
        let unknownTool = try await call(server(), """
        {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}
        """)
        #expect((unknownTool["error"] as? [String: Any])?["code"] as? Int == -32602)
        let unknownMethod = try await call(server(), #"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#)
        #expect((unknownMethod["error"] as? [String: Any])?["code"] as? Int == -32601)
        let garbage = try await call(server(), "{not json")
        #expect((garbage["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    @Test("a batch answers each request and skips notifications")
    func batch() async throws {
        let data = try #require(await server().handle(body: Data("""
        [{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]
        """.utf8)))
        let responses = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(responses.count == 1)
        #expect(responses[0]["id"] as? Int == 1)
    }
}

@Suite("HTTP request parser")
struct HTTPRequestParserTests {
    @Test("a request split across pushes completes once its body is whole")
    func split() throws {
        var parser = HTTPRequestParser()
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 10\r\n\r\n"
        #expect(try parser.push(Data(head.utf8)).isEmpty)
        #expect(try parser.push(Data("{\"a\":".utf8)).isEmpty)
        let requests = try parser.push(Data("true}".utf8))
        #expect(requests.count == 1)
        #expect(requests[0].method == "POST")
        #expect(requests[0].path == "/mcp")
        #expect(requests[0].header("Content-Type") == "application/json")
        #expect(String(decoding: requests[0].body, as: UTF8.self) == "{\"a\":true}")
    }

    @Test("pipelined requests on one connection come out in order")
    func pipelined() throws {
        var parser = HTTPRequestParser()
        let two = "GET /a HTTP/1.1\r\n\r\nPOST /b HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi"
        let requests = try parser.push(Data(two.utf8))
        #expect(requests.map(\.path) == ["/a", "/b"])
        #expect(requests[1].body == Data("hi".utf8))
    }

    @Test("chunked bodies are reassembled")
    func chunked() throws {
        var parser = HTTPRequestParser()
        let text = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        let requests = try parser.push(Data(text.utf8))
        #expect(requests.count == 1)
        #expect(String(decoding: requests[0].body, as: UTF8.self) == "hello world")
    }

    @Test("an oversized body is refused rather than buffered")
    func tooLarge() throws {
        var parser = HTTPRequestParser()
        parser.maxBodyBytes = 8
        #expect(throws: HTTPRequestParser.ParseError.bodyTooLarge) {
            try parser.push(Data("POST / HTTP/1.1\r\nContent-Length: 9\r\n\r\n".utf8))
        }
    }

    @Test("responses carry a length and keep the connection")
    func response() {
        let data = HTTPResponse.render(status: 200, headers: [("Content-Type", "application/json")], body: Data("{}".utf8))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{}"))
    }
}
