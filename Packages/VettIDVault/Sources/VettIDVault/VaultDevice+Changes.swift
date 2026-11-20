import Foundation
import VettIDCrypto

/// A request kept so that it can be sent again as the same request (VAULT-MESSAGING §11.14.9 "A lost answer"): its type,
/// inner id, `exp` and body. Kept in memory only, never on disk, until the change it carries is decided. Its body holds
/// the payload sealed to a UTK, never a secret in the clear.
public struct HeldRequest: Sendable, CustomStringConvertible {
    public let type: String
    public let id: String
    public let exp: Date
    let body: [UInt8]

    init(type: String, id: String, exp: Date, body: [UInt8]) {
        self.type = type
        self.id = id
        self.exp = exp
        self.body = body
    }

    public var description: String { "HeldRequest(\(type), \(id))" }
}

// The vault's clock as this phone last saw it, and the resend of a held request (VAULT-MESSAGING §11.14.9 "A lost
// answer").
extension VaultDevice {
    /// The vault's clock as this phone last saw it: the `ts` of the newest message from the vault plus the time elapsed
    /// since on the phone's monotonic clock, or the phone's clock while no message arrived in this process.
    public func vaultNow() -> Date {
        let up = cfg.uptime()
        guard let c = mem.withLock({ vaultClock }) else { return now() }
        return c.ts.addingTimeInterval(max(0, up - c.at))
    }

    /// A message from the vault stamped [ts]: the vault's clock moves forward with it, never back (a cached response
    /// keeps the time it was made).
    func noteVaultTime(_ ts: Date) {
        let up = cfg.uptime()
        mem.withLock {
            if let c = vaultClock, c.ts.addingTimeInterval(max(0, up - c.at)) >= ts { return }
            vaultClock = (ts, up)
        }
    }

    /// Whether a message from the vault arrived in this process: until one does, ``vaultNow()`` is the phone's clock.
    public var knowsVaultTime: Bool { mem.withLock { vaultClock != nil } }

    /// The vault opened (an unlock, a start with it open). The first answer to a request this device first sends from now
    /// (a fresh id: not a request tried again, nor a stored one, nor a redelivered or cached answer) gives the opening's
    /// moment on the vault's clock, told once to [onMark] (ANDROID-PLAN 0.1.134 Notification modes 7, IOS-PLAN §6.7). A
    /// vault time learnt before, any event's `ts` (the mailbox's backlog at a cold start can be days old) and any other
    /// answer never do. A later opening replaces it. [began]: the opening's moment on the monotonic clock when it began on
    /// an earlier device of this process (its mark not yet on the vault's clock); now when nil.
    public func beginOpening(began: TimeInterval? = nil, onMark: @escaping @Sendable (Date) -> Void) {
        let up = began ?? cfg.uptime()
        mem.withLock { opening = Opening(began: up, requests: [], onMark: onMark) }
    }

    /// The most fresh requests an opening waits on before its first answer: far more than an opening sends.
    static let openingRequestsMax = 256

    /// A request with a fresh id, first sent now.
    func noteOpeningRequest(_ id: String) {
        mem.withLock {
            guard var o = opening, o.requests.count < Self.openingRequestsMax else { return }
            o.requests.insert(id)
            opening = o
        }
    }

    /// An answer seen for the first time, to [re]: when it is the opening's first answer to one of its fresh requests whose
    /// request still waits for it (a late-collected answer, its wait ended, could pull the mark earlier than the whole wait,
    /// with its retries, allows), the opening's moment on the vault's clock (its `ts` less the time since the opening began)
    /// is told, once. The wait and the mark are both on this process's clocks: a request does not wait across the phone's
    /// sleep, since in the background the app's collection is stopped and its device let go (IOS-PLAN §6.6), so an answer
    /// collected after a sleep finds its request ended; a live call that keeps the collection keeps the phone awake.
    func noteOpeningAnswer(_ re: String, _ ts: Date) {
        let up = cfg.uptime()
        let told: (@Sendable (Date) -> Void, Date)? = mem.withLock {
            guard let o = opening, o.requests.contains(re), pending[re] != nil else { return nil }
            opening = nil
            return (o.onMark, ts.addingTimeInterval(o.began - up))
        }
        if let (tell, at) = told { tell(at) }
    }

    /// Sends [held] again (the same inner id, `exp` and body, in a new envelope, never through the outbox) and waits once
    /// for its answer: the vault answers it from its response cache if it handled it, or handles it once if it never
    /// arrived (§8.2). No answer is ``VaultStateError``.
    public func resend(_ held: HeldRequest, timeout: TimeInterval? = nil) async throws -> VaultMessage {
        try await requestKept(held, sends: 1, timeout: timeout)
    }

    /// [held] deposited at most [sends] times while its `exp` has not passed by ``vaultNow()``, each straight to the
    /// relay and never through the outbox, so that the request is never written to the phone's storage (§11.14.9 step 1:
    /// kept in memory only); a deposit that fails is a send without an answer. Its answer, ``OutboxHeld`` when the lock gate holds its first send, or ``VaultStateError``.
    func requestKept(_ held: HeldRequest, sends: Int, timeout: TimeInterval? = nil) async throws -> VaultMessage {
        try refuseSending()
        let d = OneShot<Inner>()
        mem.withLock { pending[held.id] = d }
        defer { mem.withLock { _ = pending.removeValue(forKey: held.id) } }
        var sent = false
        for n in 0..<sends where vaultNow() < held.exp {
            // (ANDROID-PLAN "While pending") Its first send the lock gate holds: nothing is sent (``OutboxHeld``). A re-send it
            // holds is not deposited: the change goes on waiting for the copy already out (``requestMayGo(_:)``).
            if n == 0, await !requestMayGo(held.type) { throw OutboxHeld() }
            if n > 0, await !requestMayGo(held.type) {
                if let inner = await d.wait(timeout: timeout ?? cfg.requestTimeout(for: held.type)) {
                    return VaultMessage(inner: countingAnswer(held.type, inner))
                }
                try Task.checkCancellation()
                continue
            }
            sent = true
            // A failed deposit is a send without an answer; a halted or quieted device refuses at once.
            do {
                _ = try await sendOnceUnlocked(id: held.id, type: held.type, body: held.body, exp: held.exp)
            } catch let e as VaultStateError where e == Self.haltedError || e == Self.quietedError {
                throw e
            } catch {}
            if let inner = await d.wait(timeout: timeout ?? cfg.requestTimeout(for: held.type)) {
                return VaultMessage(inner: countingAnswer(held.type, inner))
            }
            try Task.checkCancellation()
            // No answer: the collection may have ended (the answer would then wait in the mailbox unread).
            ensureCollecting()
        }
        // Never sent (its `exp` had passed): it cannot have counted.
        if sent { countingNoAnswer(held.type) }
        throw VaultStateError(message: "\(held.type): no response")
    }
}
