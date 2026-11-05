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
    static let pingInterval: TimeInterval = 25

    public let messages: AsyncThrowingStream<RelayMessage, Error>
    private let task: URLSessionWebSocketTask

    public init(session: URLSession, request: URLRequest) {
        let task = session.webSocketTask(with: request)
        self.task = task
        let pings = PingState()
        messages = AsyncThrowingStream { continuation in
            let reader = Task {
                while true {
                    let frame: URLSessionWebSocketTask.Message
                    do {
                        frame = try await task.receive()
                    } catch {
                        let response = task.response as? HTTPURLResponse
                        let headers = (response?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { out, kv in
                            if let k = kv.key as? String, let v = kv.value as? String { out[k] = v }
                        }
                        continuation.finish(throwing: Self.closeError(
                            code: task.closeCode.rawValue, upgradeStatus: response?.statusCode ?? 0, upgradeHeaders: headers,
                            endedByPing: pings.endedByUs, error: error
                        ))
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
            // (Chosen; not in the spec: RELAY-PROTOCOL says nothing of pings.) A ping every 25 s while the session is open keeps a
            // connection that an idle timeout on the path would drop alive, and tells a dead one by the failed ping.
            let keepalive = Self.keepalive(task, pings)
            continuation.onTermination = { _ in
                reader.cancel()
                keepalive.cancel()
            }
        }
        task.resume()
    }

    /// The ping every ``pingInterval``; a ping still unanswered at the next tick, or one that fails, ends the socket, so that
    /// `receive()` fails and the collector falls back. (After the app resumes from the background a late tick can end a
    /// live socket whose ping was never sent or answered in time; the only cost is a reconnect.)
    private static func keepalive(_ task: URLSessionWebSocketTask, _ pings: PingState) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pingInterval * 1e9))
                if Task.isCancelled { return }
                guard pings.sending() else {
                    pings.end()
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
                task.sendPing { error in
                    if error != nil {
                        pings.end()
                        task.cancel(with: .goingAway, reason: nil)
                    } else {
                        pings.answered()
                    }
                }
            }
        }
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

    /// What a session that ended with close [code] reports: nothing for a normal closure, `mailbox_unknown` for 4404, a
    /// refused upgrade ([upgradeStatus] ≥ 400) as the relay's error parser reads its status and headers (`Retry-After`,
    /// RELAY-PROTOCOL §7.2; the body of a refused upgrade is not available to `URLSessionWebSocketTask`, so the code is
    /// `http_<status>`), a transport error otherwise.
    static func closeError(
        code: Int, upgradeStatus: Int = 0, upgradeHeaders: [String: String] = [:], endedByPing: Bool = false, error: Error
    ) -> Error? {
        // The relay's own end of the mailbox wins over ours (a 4404 racing a failed ping still ends the collection).
        if code == closeMailboxUnknown { return RelayError(status: 404, code: RelayError.mailboxUnknown) }
        // A socket this side ended for an unanswered ping is no transport failure of the path to hold against the socket for
        // minutes: it is collected by long-poll for the pause of a refusal, as when a resume made a tick late (chosen; not in
        // the spec).
        if endedByPing { return RelayError(status: 503, code: "http_ping", message: "ping unanswered") }
        switch code {
        case normalClosure: return nil
        default:
            if upgradeStatus >= 400 { return RelayClient.error(HTTPAnswer(status: upgradeStatus, headers: upgradeHeaders, body: [])) }
            return code == 0 ? (error as? URLError) ?? URLError(.networkConnectionLost) : URLError(.networkConnectionLost)
        }
    }
}

/// Whether the last ping of a session was answered (``RelayStream``'s keepalive).
final class PingState: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = false
    private var ended = false

    /// A ping is due: false when the one before is still unanswered (the session is to end), else it is marked sent.
    func sending() -> Bool {
        lock.withLock {
            if outstanding { return false }
            outstanding = true
            return true
        }
    }

    func answered() { lock.withLock { outstanding = false } }

    /// The session is being ended by this side for a ping.
    func end() { lock.withLock { ended = true } }
    var endedByUs: Bool { lock.withLock { ended } }
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
    /// A session that closes normally sooner than this after it opened counts as a failed connection.
    static let minSession: TimeInterval = 2

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
        var socketRefusals = 0
        var pollUntil = Date.distantPast
        while true {
            try Task.checkCancellation()
            let useSocket = mode == .webSocket && now() > pollUntil
            let started = now()
            do {
                try await round(useSocket: useSocket, handle)
                let lasted = now().timeIntervalSince(started)
                if useSocket, lasted < Self.minSession {
                    // (chosen; not in the spec) A session the relay closes normally at once is not a connection: it is
                    // collected by long-poll for the pause of a refusal, so that a relay that accepts and closes does not
                    // draw a reconnect loop.
                    pollUntil = now().addingTimeInterval(socketPause(Self.closedNormally, socketRefusals))
                    socketRefusals += 1
                    continue
                }
                if failures > 0 { onRecovered() }
                failures = 0
                if useSocket {
                    // (chosen; not in the spec) A session that held and then closed normally (a relay restart, a deploy) is
                    // collected by long-poll for the first refusal pause before the socket is tried again, so that every
                    // phone of a restarting relay doesn't reconnect at the same instant. It isn't a refusal: the next one
                    // counts from one.
                    pollUntil = now().addingTimeInterval(socketPause(Self.closedNormally, 0))
                    socketRefusals = 1
                }
            } catch let e as RelayError {
                // An upgrade the relay refused (its code is the status's, not a relay code: 4404 is `mailbox_unknown`) is
                // collected by long-poll for the pause, whatever its status: the long-poll then meets the refusal's real
                // cause (a stale signature, a missing mailbox) and treats it as it does. Quota refusals are the long-poll's.
                let refused = useSocket && e.code.hasPrefix("http_")
                guard e.retryable || refused else { throw e }
                if !refused { failures += 1 }
                if useSocket {
                    // RELAY-PROTOCOL §7.2: a client whose upgrade is answered 429 collects by long-poll and tries the
                    // WebSocket again no sooner than retry_after, with backoff (chosen; not in the spec: 5 s, the
                    // relay's own retry_after, doubled per refusal up to the fallback period, when the answer names none).
                    // A socket that held for a while before it ended is not another refusal in a row (chosen; not in the spec).
                    socketRefusals = Self.refusalsForPause(socketRefusals, lasted: now().timeIntervalSince(started), keepsCount: refused)
                    pollUntil = now().addingTimeInterval(socketPause(e, socketRefusals))
                    socketRefusals += 1
                    // The long-poll that follows at once is the wait; it backs off itself if it fails too.
                    continue
                }
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

    /// The refusals in a row that count towards the pause: none after a session that lasted ``minSession`` or more and
    /// then failed. [keepsCount] (an `http_` answer) never resets them, however long it took: an upgrade the relay refused
    /// (the time is the handshake's, not a session's), or a socket this side ended for an unanswered ping (`http_ping`),
    /// so that a network that keeps dropping the socket backs off to the fallback period instead of reconnecting every
    /// few seconds.
    static func refusalsForPause(_ refusals: Int, lasted: TimeInterval, keepsCount: Bool = false) -> Int {
        !keepsCount && lasted >= minSession ? 0 : refusals
    }

    /// The pause of a session the relay closed normally: a refusal's without a retry_after (5 s, doubled per refusal).
    static let closedNormally = RelayError(status: 503, code: "closed")

    /// How long the long-poll stands in for a WebSocket that a retryable relay answer ended.
    func socketPause(_ e: RelayError, _ refusals: Int) -> TimeInterval {
        let base = TimeInterval(e.retryAfterSeconds > 0 ? min(e.retryAfterSeconds, RelayError.maxRetryAfterSeconds) : 5)
        // Never shorter than the relay's own retry_after (RELAY-PROTOCOL §7.2), whatever the fallback period.
        return max(base, min(base * Double(1 << min(refusals, Self.maxShift)), fallback))
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
