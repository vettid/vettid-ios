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

    /// Sends [held] again (the same inner id, `exp` and body, in a new envelope) and waits once for its answer: the
    /// vault answers it from its response cache if it handled it, or handles it once if it never arrived (§8.2). No
    /// answer is ``VaultStateError``.
    public func resend(_ held: HeldRequest, timeout: TimeInterval? = nil) async throws -> VaultMessage {
        try await request(held.type, body: held.body, timeout: timeout, innerID: held.id, exp: held.exp, retries: 0)
    }
}
