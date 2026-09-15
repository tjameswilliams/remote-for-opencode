import Foundation
import Network
import Testing

@testable import RemoteKit

/// The hub exists because of one bad night: every phone reconnect opened
/// its own event stream to OpenCode, half-open connections kept those
/// streams alive, and six of them starved every other request. These
/// tests pin the properties that prevent a repeat, against a real HTTP
/// server on the loopback interface: one socket however many subscribers,
/// the socket released when the last subscriber leaves, and a server that
/// hangs up ending every subscriber's stream.
@Suite("Event stream hub", .serialized)
struct EventStreamHubTests {
    @Test("Subscribers share one upstream socket and each receives every event")
    func fanOut() async throws {
        let server = try await SSEServer()
        let hub = EventStreamHub()
        let url = await server.url

        var first = await hub.subscribe(url).makeAsyncIterator()
        var second = await hub.subscribe(url).makeAsyncIterator()
        try await server.waitForConnections(1)
        // Time for the second subscriber to have opened a socket if it
        // wrongly did; it must not.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await server.connectionsOpened == 1)
        #expect(await hub.openStreams == 1)

        await server.send("data: {\"n\":1}\n\n")
        await server.send("data: {\"n\":2}\n\n")
        #expect(try await first.next() == "{\"n\":1}")
        #expect(try await first.next() == "{\"n\":2}")
        #expect(try await second.next() == "{\"n\":1}")
        #expect(try await second.next() == "{\"n\":2}")

        // A late subscriber joins the existing socket and hears only what
        // comes after it subscribed; onConnected fires straight away.
        let connected = Flag()
        var third = await hub.subscribe(url) { connected.raise() }.makeAsyncIterator()
        #expect(connected.raised)
        await server.send("data: 3\n\n")
        #expect(try await third.next() == "3")
        #expect(await server.connectionsOpened == 1)
        await server.stop()
    }

    @Test("The upstream closes when the last subscriber leaves, not before")
    func releaseOnLastUnsubscribe() async throws {
        let server = try await SSEServer()
        let hub = EventStreamHub()
        let url = await server.url

        let one = Task { for try await _ in await hub.subscribe(url) {} }
        let two = Task { for try await _ in await hub.subscribe(url) {} }
        try await server.waitForConnections(1)

        one.cancel()
        _ = await one.result
        try await Task.sleep(for: .milliseconds(300))
        #expect(await server.connectionsClosed == 0)
        #expect(await hub.openStreams == 1)

        two.cancel()
        _ = await two.result
        try await server.waitForClosed(1)
        #expect(await hub.openStreams == 0)

        // The next subscriber gets a fresh socket.
        let three = Task { for try await _ in await hub.subscribe(url) {} }
        try await server.waitForConnections(2)
        three.cancel()
        _ = await three.result
        await server.stop()
    }

    @Test("A server that hangs up ends every subscriber, and a fresh one reconnects")
    func serverHangsUp() async throws {
        let server = try await SSEServer()
        let hub = EventStreamHub()
        let url = await server.url

        let received = Counter()
        let ended = Counter()
        let consumers = (0 ..< 3).map { _ in
            Task {
                do {
                    for try await _ in await hub.subscribe(url) { received.increment() }
                } catch {}
                ended.increment()
            }
        }
        try await server.waitForConnections(1)
        await server.send("data: hello\n\n")
        try await received.waitFor(3)

        await server.hangUp()
        for consumer in consumers { _ = await consumer.result }
        #expect(ended.value == 3)
        #expect(await hub.openStreams == 0)

        let late = Task { for try await _ in await hub.subscribe(url) {} }
        try await server.waitForConnections(2)
        late.cancel()
        _ = await late.result
        await server.stop()
    }
}

// MARK: - Fixtures

/// Just enough HTTP/1.1 to serve `text/event-stream` on the loopback
/// interface: accept, read the request, answer with headers, then write
/// whatever the test hands it until told to hang up.
private actor SSEServer {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private(set) var connectionsOpened = 0
    private(set) var connectionsClosed = 0
    private(set) var url = URL(string: "http://127.0.0.1:0/event")!

    init() async throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params)
        self.listener = listener
        // Must be in place before `start`, or the listener fails with EINVAL.
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var settled = false
            listener.stateUpdateHandler = { state in
                guard !settled else { return }
                switch state {
                case .ready:
                    settled = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error):
                    settled = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
        url = URL(string: "http://127.0.0.1:\(port)/event")!
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connectionsOpened += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.noteClosed() }
            default:
                break
            }
        }
        connection.start(queue: .global())
        // Consume the request, then answer. The body is delimited by the
        // connection closing, which is what URLSession expects of a stream
        // with neither Content-Length nor chunking.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n"
            connection.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in })
            // Keep reading so a peer's FIN or RST is noticed.
            func drain() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    _, _, isComplete, error in
                    if isComplete || error != nil {
                        connection.cancel()
                    } else {
                        drain()
                    }
                }
            }
            drain()
        }
    }

    private func noteClosed() {
        connectionsClosed += 1
    }

    func send(_ text: String) {
        for connection in connections {
            connection.send(content: text.data(using: .utf8), completion: .contentProcessed { _ in })
        }
    }

    func hangUp() {
        for connection in connections { connection.cancel() }
        connections = []
    }

    func stop() {
        hangUp()
        listener.cancel()
    }

    func waitForConnections(_ count: Int) async throws {
        try await poll { self.connectionsOpened >= count }
    }

    func waitForClosed(_ count: Int) async throws {
        try await poll { self.connectionsClosed >= count }
    }

    private func poll(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("condition not met within five seconds")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var raised: Bool { lock.withLock { value } }
    func raise() { lock.withLock { value = true } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func waitFor(_ target: Int) async throws {
        for _ in 0 ..< 200 {
            if value >= target { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("expected \(target), have \(value)")
    }
}
