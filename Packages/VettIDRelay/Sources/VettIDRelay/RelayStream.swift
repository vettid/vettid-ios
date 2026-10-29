import Foundation
import VettIDCrypto

/// A collect session that delivers messages until it ends (RELAY-PROTOCOL §6.4).
public protocol CollectStream: Sendable {
    /// The messages; the sequence finishes when the session closes normally and throws a ``RelayError``
    /// (`mailbox_unknown` for close code 4404) or a transport error when it fails.
    var messages: AsyncThrowingStream<RelayMessage, Error> { get }
    /// Acks a message over the session; false if it is closed.
    func ack(_ msgID: String) async -> Bool
    func close()
}

/// A WebSocket collect session (§6.4) on `URLSessionWebSocketTask`: server frames are messages with the same lease as
/// long-poll; the client acks with `{"ack": msg_id}`. A malformed frame is dropped (the lease brings the message back).
/// Mirrors vettid-android `RelayStream`.
public final class RelayStream: CollectStream, @unchecked Sendable {
    public static let normalClosure = 1000
    public static let closeMailboxUnknown = 4404

    public let messages: AsyncThrowingStream<RelayMessage, Error>
    private let task: URLSessionWebSocketTask

    public init(session: URLSession, request: URLRequest) {
        let task = session.webSocketTask(with: request)
        self.task = task
        messages = AsyncThrowingStream { continuation in
            let reader = Task {
                while true {
                    let frame: URLSessionWebSocketTask.Message
                    do {
                        frame = try await task.receive()
                    } catch {
                        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
                        continuation.finish(throwing: Self.closeError(code: task.closeCode.rawValue, upgradeStatus: status, error: error))
                        return
                    }
                    let text: String? = switch frame {
                    case .string(let s): s
                    case .data(let d): String(bytes: d, encoding: .utf8)
                    @unknown default: nil
                    }
                    guard let text, let o = try? StrictJson.parseObject(Array(text.utf8)), let m = try? RelayMessage.parse(o) else {
                        continue
                    }
                    continuation.yield(m)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
        task.resume()
    }

    public func ack(_ msgID: String) async -> Bool {
        guard task.closeCode == .invalid else { return false }
        do {
            try await task.send(.string(JsonBuilder().string("ack", msgID).build()))
            return true
        } catch {
            return false
        }
    }

    public func close() { task.cancel(with: .normalClosure, reason: nil) }

    /// What a session that ended with close [code] reports: nothing for a normal closure, `mailbox_unknown` for 4404,
    /// the HTTP status of a refused upgrade ([upgradeStatus] ≥ 400) as `http_<status>`, a transport error otherwise.
    static func closeError(code: Int, upgradeStatus: Int = 0, error: Error) -> Error? {
        switch code {
        case normalClosure: return nil
        case closeMailboxUnknown: return RelayError(status: 404, code: RelayError.mailboxUnknown)
        default:
            if upgradeStatus >= 400 { return RelayError(status: upgradeStatus, code: "http_\(upgradeStatus)") }
            return code == 0 ? (error as? URLError) ?? URLError(.networkConnectionLost) : URLError(.networkConnectionLost)
        }
    }
}

/// What a ``MailboxCollector`` collects from: a relay client, or a fake in tests.
public protocol MailboxSource: Sendable {
    func collect(wait: TimeInterval, max: Int) async throws -> [RelayMessage]
    func ack(_ msgID: String) async throws
    func openStream() throws -> CollectStream
}

/// The relay client as a ``MailboxSource``, streaming over [transport]'s session with its origin map.
public struct RelayMailbox: MailboxSource {
    public let client: RelayClient
    public let transport: HTTPTransport

    public init(client: RelayClient, transport: HTTPTransport) {
        self.client = client
        self.transport = transport
    }

    public func collect(wait: TimeInterval, max: Int) async throws -> [RelayMessage] { try await client.collect(wait: wait, max: max) }
    public func ack(_ msgID: String) async throws { try await client.ack(msgID) }
    public func openStream() throws -> CollectStream {
        RelayStream(session: transport.session, request: RelayClient.webSocket(transport.prepared(try client.streamRequest())))
    }
}

/// Thrown by a ``MailboxCollector`` handler for a message it cannot process yet but must not lose (a message of an
/// epoch whose `hs.fin` has not arrived, VAULT-MESSAGING §6.3): the collector does not ack it, so the relay delivers
/// it again after its lease.
public struct LeaveUnacked: Error, Sendable {
    public let reason: String

    public init(_ reason: String) { self.reason = reason }
}

/// Collects one mailbox until cancelled (RELAY-PROTOCOL §6.3, §6.4): each message goes to the handler, which processes
/// and persists it, and is acked only after the handler returns (at-least-once; the handler dedupes by msg_id). A
/// long-poll is re-issued immediately after every response. In ``Mode/webSocket`` the collector streams and falls back
/// to long-poll for [fallback] after a socket failure.
///
/// Transport errors, `429 rate_limited`, 5xx and a stale or replayed signature back off with jitter (0.25 s × 2ⁿ,
/// capped at 30 s). Terminal relay errors end ``run(_:)``: `mailbox_unknown` and every other client error. The owner
/// restarts it. Mirrors vettid-android `MailboxCollector`.
public struct MailboxCollector: Sendable {
    public enum Mode: Sendable { case longPoll, webSocket }

    static let base: TimeInterval = 0.25
    static let maxShift = 7
    static let maxDelay: TimeInterval = 30
    static let jitter: TimeInterval = 0.25

    let source: MailboxSource
    let mode: Mode
    let wait: TimeInterval
    let fallback: TimeInterval
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let random: @Sendable (ClosedRange<TimeInterval>) -> TimeInterval
    /// Called with true when a collect request goes out (a long-poll round, or a stream opened) and with false when it
    /// ended. A long poll answers at once when messages wait, so one that has been out a while found the mailbox empty.
    let onRequest: @Sendable (Bool) -> Void
    /// Called when a collect round succeeded after failed ones: the relay connection is back.
    let onRecovered: @Sendable () -> Void

    public init(
        source: MailboxSource,
        mode: Mode = .longPoll,
        wait: TimeInterval = RelayClient.defaultWait,
        fallback: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
        random: @escaping @Sendable (ClosedRange<TimeInterval>) -> TimeInterval = { TimeInterval.random(in: $0) },
        onRequest: @escaping @Sendable (Bool) -> Void = { _ in },
        onRecovered: @escaping @Sendable () -> Void = {}
    ) {
        self.source = source
        self.mode = mode
        self.wait = wait
        self.fallback = fallback
        self.now = now
        self.sleep = sleep
        self.random = random
        self.onRequest = onRequest
        self.onRecovered = onRecovered
    }

    /// Runs until cancelled or a terminal relay error.
    public func run(_ handle: @Sendable (RelayMessage) async throws -> Void) async throws {
        var failures = 0
        var pollUntil = Date.distantPast
        while true {
            try Task.checkCancellation()
            let useSocket = mode == .webSocket && now() > pollUntil
            do {
                try await round(useSocket: useSocket, handle)
                if failures > 0 { onRecovered() }
                failures = 0
            } catch let e as RelayError {
                guard e.retryable else { throw e }
                failures += 1
                try await sleep(retryDelay(failures, e.retryAfterSeconds))
            } catch is URLError {
                // Transport failures only: a handler's own error (storage, decoding) ends the run, as in vettid-android.
                try Task.checkCancellation()
                if useSocket { pollUntil = now().addingTimeInterval(fallback) }
                failures += 1
                try await sleep(retryDelay(failures, 0))
            }
        }
    }

    private func round(useSocket: Bool, _ handle: @Sendable (RelayMessage) async throws -> Void) async throws {
        onRequest(true)
        defer { onRequest(false) }
        if useSocket { try await stream(handle) } else { _ = try await pollOnce(handle) }
    }

    /// One long-poll round: collects, handles and acks each message. Returns how many arrived.
    public func pollOnce(_ handle: @Sendable (RelayMessage) async throws -> Void) async throws -> Int {
        let msgs = try await source.collect(wait: wait, max: RelayClient.defaultMax)
        for m in msgs where try await handled(m, handle) { try await source.ack(m.msgID) }
        return msgs.count
    }

    private func stream(_ handle: @Sendable (RelayMessage) async throws -> Void) async throws {
        let s = try source.openStream()
        defer { s.close() }
        for try await m in s.messages where try await handled(m, handle) {
            if !(await s.ack(m.msgID)) { try await source.ack(m.msgID) }
        }
    }

    /// Hands [m] to [handle]; false when the handler left it for redelivery (``LeaveUnacked``).
    private func handled(_ m: RelayMessage, _ handle: @Sendable (RelayMessage) async throws -> Void) async throws -> Bool {
        do {
            try await handle(m)
            return true
        } catch is LeaveUnacked {
            return false
        }
    }

    func retryDelay(_ failures: Int, _ retryAfterSeconds: Int) -> TimeInterval {
        if retryAfterSeconds > 0 { return Double(min(retryAfterSeconds, RelayError.maxRetryAfterSeconds)) + random(0...Self.jitter) }
        let cap = min(Self.base * Double(1 << min(failures, Self.maxShift)), Self.maxDelay)
        return random((cap / 2)...cap)
    }
}
