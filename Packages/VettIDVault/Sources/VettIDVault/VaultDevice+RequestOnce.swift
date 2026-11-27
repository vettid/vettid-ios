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
        var waited: TimeInterval = 0
        for at in resendAfter.sorted() where at > waited && at < total {
            if let inner = await d.wait(timeout: at - waited) { return VaultMessage(inner: countingAnswer(type, inner)) }
            try Task.checkCancellation()
            waited = at
            // Held by the lock gate meanwhile: not deposited again, and the wait goes on to its end.
            if await requestMayGo(type) { _ = try? await sendOnceUnlocked(id: id, type: type, body: body, exp: exp) }
        }
        guard let inner = await d.wait(timeout: total - waited) else {
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
