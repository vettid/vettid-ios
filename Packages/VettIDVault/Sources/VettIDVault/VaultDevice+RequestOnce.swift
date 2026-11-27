import Foundation
import VettIDCrypto

// A request deposited once (VAULT-MESSAGING §8.1, no §8.6 re-send): the lock, the `credential.ack`, the settle probe,
// `call.start`.
extension VaultDevice {
    /// A request deposited once (``sendOnce(_:body:exp:)``) and awaited for [timeout]: never kept for a later flush, unlike
    /// ``request(_:body:timeout:innerID:)``. [exp]: the vault drops the request after it (§5.3). [resendAfter]: the times
    /// (seconds after the first deposit, within [timeout]) at which the same request, with the same inner `id`, is deposited
    /// again while no answer has come (an application retry, §8.6; `call.start` at 10 s and 20 s, §10.10 "Placing a
    /// call"). The first answer is the one used; a deposit that fails then is not an end: the wait goes on. A resend goes
    /// only while [mayResend] says so (the caller's: the call still wanted) and only while nothing has stopped this request
    /// going since its first deposit: once the lock gate held one resend, or the device stopped, no other goes, though the
    /// gate opens again when the vault has taken the lock. A resend still out when the wait ends is cancelled.
    public func requestOnce(
        _ type: String, body: [UInt8] = VaultJSON.empty, timeout: TimeInterval? = nil, exp: Date? = nil,
        resendAfter: [TimeInterval] = [], mayResend: (@Sendable () async -> Bool)? = nil
    ) async throws -> VaultMessage {
        let id = Ulid.new(now())
        let d = OneShot<Inner>()
        mem.withLock { pending[id] = d }
        defer { mem.withLock { _ = pending.removeValue(forKey: id) } }
        // Held by the lock gate: nothing is sent (``requestMayGo(_:)``).
        guard await requestMayGo(type) else { throw OutboxHeld() }
        let mark = stopMark
        let total = timeout ?? cfg.requestTimeout(for: type)
        // The times count from the first deposit's start, on a clock that cannot be set back: a slow deposit (the relay
        // client's own tries) delays neither a resend nor the end of the wait, and each resend is deposited beside the wait.
        let sent = ContinuousClock.now
        func left(until at: TimeInterval) -> TimeInterval {
            let elapsed = sent.duration(to: .now)
            return max(0, at - Double(elapsed.components.seconds) - Double(elapsed.components.attoseconds) / 1e18)
        }
        _ = try await countingSend(type) { try await sendOnceUnlocked(id: id, type: type, body: body, exp: exp) }
        var resends: [Task<Void, Never>] = []
        defer { resends.forEach { $0.cancel() } }
        var stopped = false
        for at in resendAfter.sorted() where at > 0 && at < total {
            if let inner = await d.wait(timeout: left(until: at)) { return VaultMessage(inner: countingAnswer(type, inner)) }
            try Task.checkCancellation()
            if !stopped { stopped = await !mayResendNow(type, since: mark, mayResend) }
            if !stopped {
                resends.append(Task { _ = try? await self.sendOnceUnlocked(id: id, type: type, body: body, exp: exp) })
            }
        }
        guard let inner = await d.wait(timeout: left(until: total)) else {
            try Task.checkCancellation()
            countingNoAnswer(type)
            throw VaultStateError(message: "\(type): no response")
        }
        return VaultMessage(inner: countingAnswer(type, inner))
    }

    /// Whether a resend of a request first deposited at [mark] (``stopMark``) may go: no stop since, the lock gate open
    /// (``requestMayGo(_:)``), and the caller's [mayResend].
    private func mayResendNow(_ type: String, since mark: Int, _ mayResend: (@Sendable () async -> Bool)?) async -> Bool {
        guard mem.withLock({ stops == mark && !forgotten }), await requestMayGo(type) else { return false }
        if let mayResend, await !mayResend() { return false }
        return mem.withLock { stops == mark && !forgotten }
    }

    /// ``requestOnce(_:body:timeout:exp:resendAfter:mayResend:)``, returning the body of an ok response or throwing
    /// ``VaultOpError``.
    public func opOnce(
        _ type: String, body: [UInt8] = VaultJSON.empty, timeout: TimeInterval? = nil, exp: Date? = nil,
        resendAfter: [TimeInterval] = [], mayResend: (@Sendable () async -> Bool)? = nil
    ) async throws -> [UInt8] {
        try Self.okBody(
            type, try await requestOnce(type, body: body, timeout: timeout, exp: exp, resendAfter: resendAfter, mayResend: mayResend)
        )
    }
}
