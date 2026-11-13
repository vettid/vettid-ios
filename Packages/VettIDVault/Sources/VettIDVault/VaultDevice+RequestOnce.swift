import Foundation
import VettIDCrypto

// A request deposited once (VAULT-MESSAGING §8.1, no §8.6 re-send): the lock, the `credential.ack`, the settle probe,
// `call.start`.
extension VaultDevice {
    /// A request deposited once (``sendOnce(_:body:exp:)``) and awaited for [timeout]: no second deposit, unlike
    /// ``request(_:body:timeout:innerID:)``. [exp]: the vault drops the request after it (§5.3).
    public func requestOnce(
        _ type: String, body: [UInt8] = VaultJSON.empty, timeout: TimeInterval? = nil, exp: Date? = nil
    ) async throws -> VaultMessage {
        let id = Ulid.new(now())
        let d = OneShot<Inner>()
        mem.withLock { pending[id] = d }
        defer { mem.withLock { _ = pending.removeValue(forKey: id) } }
        // Held by the lock gate: nothing is sent (``requestMayGo(_:)``).
        guard await requestMayGo(type) else { throw OutboxHeld() }
        _ = try await countingSend(type) { try await sendOnceUnlocked(id: id, type: type, body: body, exp: exp) }
        guard let inner = await d.wait(timeout: timeout ?? cfg.requestTimeout(for: type)) else {
            try Task.checkCancellation()
            countingNoAnswer(type)
            throw VaultStateError(message: "\(type): no response")
        }
        return VaultMessage(inner: countingAnswer(type, inner))
    }

    /// ``requestOnce(_:body:timeout:exp:)``, returning the body of an ok response or throwing ``VaultOpError``.
    public func opOnce(
        _ type: String, body: [UInt8] = VaultJSON.empty, timeout: TimeInterval? = nil, exp: Date? = nil
    ) async throws -> [UInt8] {
        try Self.okBody(type, try await requestOnce(type, body: body, timeout: timeout, exp: exp))
    }
}
