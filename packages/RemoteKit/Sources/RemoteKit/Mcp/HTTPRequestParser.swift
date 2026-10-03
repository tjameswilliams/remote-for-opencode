import Foundation

/// One parsed HTTP/1.1 request. Header names are lowercased.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Just enough HTTP/1.1 to serve a loopback MCP endpoint to OpenCode's
/// client: request line, headers, a body sized by Content-Length or sent
/// chunked, and several requests back to back on one kept-alive
/// connection. Bytes arrive in whatever pieces the socket delivers; the
/// parser keeps what it can't finish and returns each request once whole.
public struct HTTPRequestParser {
    public enum ParseError: Error, Equatable {
        case malformedRequestLine
        case malformedChunk
        case bodyTooLarge
    }

    /// Anything past this is refused rather than buffered: a tool call
    /// is a few kilobytes, and the endpoint is not a file upload.
    public var maxBodyBytes = 4 << 20

    private var buffer = Data()

    public init() {}

    /// Feeds bytes in; returns every request completed by them.
    public mutating func push(_ data: Data) throws -> [HTTPRequest] {
        buffer.append(data)
        var requests: [HTTPRequest] = []
        while let request = try next() { requests.append(request) }
        return requests
    }

    private mutating func next() throws -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headText = String(decoding: buffer[buffer.startIndex ..< headerEnd.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw ParseError.malformedRequestLine }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { throw ParseError.malformedRequestLine }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let bodyStart = headerEnd.upperBound
        let body: Data
        let consumedEnd: Data.Index
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let (decoded, end) = try decodeChunked(from: bodyStart) else { return nil }
            body = decoded
            consumedEnd = end
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard length <= maxBodyBytes else { throw ParseError.bodyTooLarge }
            guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return nil }
            body = Data(buffer[bodyStart ..< bodyStart + length])
            consumedEnd = bodyStart + length
        }
        buffer = Data(buffer[consumedEnd...])
        return HTTPRequest(
            method: String(parts[0]), path: String(parts[1]), headers: headers, body: body
        )
    }

    /// Chunked bodies: `<hex size>\r\n<bytes>\r\n` repeated, then a zero
    /// chunk and an empty trailer line. Nil until the whole body is here.
    private func decodeChunked(from start: Data.Index) throws -> (Data, Data.Index)? {
        var cursor = start
        var body = Data()
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = buffer.range(of: crlf, in: cursor ..< buffer.endIndex) else { return nil }
            let sizeText = String(decoding: buffer[cursor ..< lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw ParseError.malformedChunk
            }
            cursor = lineEnd.upperBound
            if size == 0 {
                // Trailers, if any, end with an empty line.
                guard let trailerEnd = buffer.range(of: crlf, in: cursor ..< buffer.endIndex) else { return nil }
                var end = trailerEnd.upperBound
                if trailerEnd.lowerBound != cursor {
                    guard let blank = buffer.range(of: Data("\r\n\r\n".utf8), in: cursor ..< buffer.endIndex)
                    else { return nil }
                    end = blank.upperBound
                }
                return (body, end)
            }
            guard body.count + size <= maxBodyBytes else { throw ParseError.bodyTooLarge }
            guard buffer.endIndex - cursor >= size + 2 else { return nil }
            body.append(buffer[cursor ..< cursor + size])
            cursor += size + 2
        }
    }
}

/// Renders a response the way this server always answers: a body, closed
/// with Content-Length, on a kept-alive connection.
public enum HTTPResponse {
    public static func render(
        status: Int, headers: [(String, String)] = [], body: Data = Data()
    ) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(for: status))\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n"
        return Data(text.utf8) + body
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Status"
        }
    }
}
