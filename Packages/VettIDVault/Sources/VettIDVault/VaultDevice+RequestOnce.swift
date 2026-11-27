import Foundation
import VettIDCrypto

// A request deposited once (VAULT-MESSAGING §8.1, no §8.6 re-send): the lock, the `credential.ack`, the settle probe,
// `call.start`.
extension VaultDevice {
    /// A request deposited once (``sendOnce(_:body:exp:)``) and awaited for [timeout]: never kept for a later flush, unlike
    /// ``request(_:body:timeout:innerID:)``. [exp]: the vault drops the request after it (§5.3). [resendAfter]: the times
    /// (seconds after the first deposit, within [timeout]) at which the same request, with the same inner `id`, is deposited
    /// again while no answer has come (an application retry, §8.6; `call.start` at 10 s and 20 s, §10.10 "Placing a
    /// call"). The first answer is the one used; a deposit that fails then is not an end: the wait goes on.
    public func requestOnce(
        _ type: String, body: [UInt8] = VaultJSON.empty, timeout: TimeInterval? = nil, exp: Date? = nil,
        resendAfter: [TimeInterval] = []
    ) async throws -> VaultMessage {
        let id = Ulid.new(now())
        let d = OneShot<Inner>()
        mem.withLock { pending[id] = d }
        defer { mem.withLock { _ = pending.removeValue(forKey: id) } }
        // Held by the lock gate: nothing is sent (``requestMayGo(_:)``).
        guard await requestMayGo(type) else { throw OutboxHeld() }
        _ = try await countingSend(type) { try await sendOnceUnlocked(id: id, type: type, body: body, exp: exp) }
        let total = timeout ?? cfg.requestTimeout(for: type)
        // The times count from the first deposit, on a clock that cannot be set back: a slow resend delays neither the next
        // one nor the end of the wait (each resend is deposited beside the wait, not in it).
        let sent = ContinuousClock.now
        func left(until at: TimeInterval) -> TimeInterval {
            let elapsed = sent.duration(to: .now)
            return max(0, at - Double(elapsed.components.seconds) - Double(elapsed.components.attoseconds) / 1e18)
        }
        for at in resendAfter.sorted() where at > 0 && at < total {
            if let inner = await d.wait(timeout: left(until: at)) { return VaultMessage(inner: countingAnswer(type, inner)) }
            try Task.checkCancellation()
            // Held by the lock gate meanwhile: not deposited again, and the wait goes on to its end.
            if await requestMayGo(type) {
                Task { _ = try? await self.sendOnceUnlocked(id: id, type: type, body: body, exp: exp) }
            }
        }
        guard let inner = await d.wait(timeout: left(until: total)) else {
            try Task.checkCancellation()
            countingNoAnswer(type)
            throw VaultStateError(message: "\(type): no response")
        }
        return VaultMessage(inner: countingAnswer(type, inner))
    }

    /// ``requestOnce(_:body:timeout:exp:)``, returning the body of an ok response or throwing ``VaultOpError``.
    public func opOnce(
        _ type: String, body: [UInt8] = VaultJSON.empty, timeout: TimeInterval? = nil, exp: Date? = nil,
        resendAfter: [TimeInterval] = []
    ) async throws -> [UInt8] {
        try Self.okBody(type, try await requestOnce(type, body: body, timeout: timeout, exp: exp, resendAfter: resendAfter))
    }
}
