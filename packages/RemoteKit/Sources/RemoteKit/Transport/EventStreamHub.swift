import Foundation

/// One server-sent-events subscription per URL, fanned out to every
/// consumer that wants it.
///
/// Why this exists: OpenCode's `/event` feed is instance-wide, so a phone
/// watching a thread, the desktop window watching the same thread, and a
/// turn in flight all want the very same bytes. Opening a stream per
/// consumer was the design until the night it filled the URLSession
/// connection pool: half-open phone connections kept their watches alive,
/// each watch kept a stream, and once six were held nothing else could
/// reach OpenCode at all, including the health check that gates `ready`.
/// Sharing means the number of streams is bounded by the number of
/// OpenCode instances, not by how many times a phone reconnected.
///
/// The streams also get a session of their own, sized so that even a
/// pathological number of them cannot starve one-shot requests.
///
/// Consumers receive the `data:` payload of each event as a string, in
/// order, from the moment they subscribed. The upstream opens with the
/// first subscriber and closes with the last; if the server ends it, every
/// subscriber's stream ends the same way (thrown error or clean finish),
/// and the next subscriber opens a fresh one.
public actor EventStreamHub {
    public static let shared = EventStreamHub()

    private final class Upstream {
        /// Distinguishes this upstream from a replacement for the same URL
        /// that may already exist by the time a stale callback arrives.
        let token = UUID()
        var task: Task<Void, Never>?
        var connected = false
        var subscribers: [UUID: AsyncThrowingStream<String, Error>.Continuation] = [:]
        /// Callbacks waiting for the socket to actually connect.
        var awaitingConnection: [@Sendable () -> Void] = []
    }

    private var upstreams: [URL: Upstream] = [:]
    private let session: URLSession

    /// A session for long-lived streams only. The per-host cap is what this
    /// whole type is defending against: URLSession's default of 6 counts a
    /// stream that stays open for hours exactly like a request that returns
    /// in a millisecond. Idle timeout is generous because a stream that
    /// carries a heartbeat every ten seconds is healthy, not stuck.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 32
        config.timeoutIntervalForRequest = 90
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    public init(session: URLSession = EventStreamHub.makeSession()) {
        self.session = session
    }

    /// Subscribes to `url`, opening the upstream if this is its first
    /// consumer. `onConnected` fires once the socket is open, immediately
    /// if it already was, so a caller can hold off an action whose
    /// consequences must not race the subscription.
    public func subscribe(
        _ url: URL, onConnected: (@Sendable () -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let upstream = upstreams[url] ?? open(url)
        let id = UUID()
        let stream = AsyncThrowingStream<String, Error> { continuation in
            upstream.subscribers[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id, from: url) }
            }
        }
        if let onConnected {
            if upstream.connected {
                onConnected()
            } else {
                upstream.awaitingConnection.append(onConnected)
            }
        }
        return stream
    }

    /// How many upstream connections are open right now. Diagnostics and
    /// tests; the number a healthy companion shows is the number of
    /// OpenCode instances anyone is looking at.
    public var openStreams: Int { upstreams.count }

    private func open(_ url: URL) -> Upstream {
        let upstream = Upstream()
        let token = upstream.token
        upstreams[url] = upstream
        // Detached: the reader must not inherit the actor, or every line
        // of every stream would be parsed on the hub's executor.
        upstream.task = Task.detached { [session] in
            do {
                let (bytes, _) = try await session.bytes(from: url)
                await self.connected(url, token: token)
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    await self.broadcast(String(line.dropFirst(6)), url: url, token: token)
                }
                await self.ended(url, token: token, error: nil)
            } catch {
                await self.ended(url, token: token, error: error)
            }
        }
        return upstream
    }

    private func current(_ url: URL, token: UUID) -> Upstream? {
        guard let upstream = upstreams[url], upstream.token == token else { return nil }
        return upstream
    }

    private func connected(_ url: URL, token: UUID) {
        guard let upstream = current(url, token: token) else { return }
        upstream.connected = true
        let waiting = upstream.awaitingConnection
        upstream.awaitingConnection = []
        for callback in waiting { callback() }
    }

    private func broadcast(_ payload: String, url: URL, token: UUID) {
        guard let upstream = current(url, token: token) else { return }
        for continuation in upstream.subscribers.values {
            continuation.yield(payload)
        }
    }

    private func ended(_ url: URL, token: UUID, error: Error?) {
        guard let upstream = current(url, token: token) else { return }
        upstreams[url] = nil
        // A cancellation is this hub closing an upstream nobody wants any
        // more; there is no one left to tell. Anything else is the server
        // going away, which every subscriber needs to hear about.
        let subscribers = upstream.subscribers
        upstream.subscribers = [:]
        for continuation in subscribers.values {
            if let error, !(error is CancellationError) {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
        // Whoever was waiting to be told "connected" will never be: fire
        // them so a caller gated on the callback does not hang. The stream
        // they hold ends right away, which tells them the rest.
        let waiting = upstream.awaitingConnection
        upstream.awaitingConnection = []
        for callback in waiting { callback() }
    }

    private func unsubscribe(_ id: UUID, from url: URL) {
        guard let upstream = upstreams[url], upstream.subscribers[id] != nil else { return }
        upstream.subscribers[id] = nil
        guard upstream.subscribers.isEmpty else { return }
        upstreams[url] = nil
        upstream.task?.cancel()
    }
}
