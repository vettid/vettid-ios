#if DEBUG
import Foundation
import VettIDCrypto
import VettIDTesting

// TEST ONLY. New phone secret and Delete vault as vettid-vault answers them: `vault.secret.renew` (VAULT-MESSAGING
// §11.14.9, `features/credential/releaser.go` `changeSecret`: the pair checked as an owner check, the next epoch's
// secret stored, the CEK rotated) and `vault.delete` (§12.5, `features/credential/credential.go` `vaultDelete` and
// `vault/delete.go`: the phrase, the PIN, then the blob and the password; `{}`, `device.unlinked{vault_deleted}` to this
// phone, and the vault gone: its mailbox refuses every deposit and the member API says there is no vault).
extension FakeVaultService {
    static let typeSecretRenew = "vault.secret.renew"
    static let typeVaultDelete = "vault.delete"
    static let deletePhrase = "delete my vault"

    /// What the vault received in one `vault.secret.renew`.
    public struct RenewSeen: Sendable {
        public let pin: String
        public let password: String
        public let newUnlockSecret: [UInt8]
    }

    /// What the vault received in one `vault.delete`.
    public struct DeleteSeen: Sendable {
        public let confirm: String?
        public let pin: String
        public let password: String
    }

    // MARK: - Switches and what was seen

    public var renews: [RenewSeen] { locked { renewsValue } }
    public var deletes: [DeleteSeen] { locked { deletesValue } }
    /// Whether the vault deleted itself.
    public var vaultDeleted: Bool { locked { vaultDeletedValue } }

    /// The member API still lists the vault after it deleted itself (the `deleted` event not yet recorded), until false.
    public var statusLagsDeletion: Bool {
        get { locked { statusLagsDeletionValue } }
        set { locked { statusLagsDeletionValue = newValue } }
    }

    /// Once the vault deleted itself, the next [n] polls of a result slot that is done answer `queued` (the vault's answer
    /// reaches the phone late, after what the vault sent to its mailbox); 0 lets the results through. It holds back every
    /// done slot, whatever its request, not only the unlock's.
    public var slotQueuedAfterDeletion: Int {
        get { locked { slotQueuedAfterDeletionValue } }
        set { locked { slotQueuedAfterDeletionValue = newValue } }
    }

    /// From now on each answer of `GET /api/vault/status` (as it is when asked) reaches the phone only at
    /// ``releaseStatusReads()``.
    public func holdStatusReads() { locked { statusGateValue = FakeHTTPServer.Gate() } }

    /// The answers of `GET /api/vault/status` held now.
    public var heldStatusReads: Int { locked { statusGateValue?.waiting ?? 0 } }

    /// Lets the held answers of `GET /api/vault/status` through, and every later one at once.
    public func releaseStatusReads() {
        let gate: FakeHTTPServer.Gate? = locked {
            defer { statusGateValue = nil }
            return statusGateValue
        }
        gate?.open()
    }

    // MARK: - The requests

    /// `vault.secret.renew` and `vault.delete`; then ``credentialRequest(_:_:)``. Callers hold ``cond``.
    func secretsRequest(_ m: Inner, _ body: JsonObject) throws {
        switch m.type {
        case Self.typeSecretRenew: try secretRenew(m, body)
        case Self.typeVaultDelete: try vaultDelete(m, body)
        default: try credentialRequest(m, body)
        }
    }

    /// `vault.secret.renew`: checked as an owner check; a new secret of 32 bytes stored (the PIN unchanged), the CEK
    /// rotated. Callers hold ``cond``.
    func secretRenew(_ m: Inner, _ body: JsonObject) throws {
        guard let p = try opened(m, body) else { return }
        let seen = RenewSeen(
            pin: (try? p.string("pin")) ?? "", password: (try? p.string("password")) ?? "",
            newUnlockSecret: (try? p.base64("new_unlock_secret")) ?? []
        )
        renewsValue.append(seen)
        guard try checkSecrets(m, pin: seen.pin, password: seen.password, blob: try body.optString("credential")) else { return }
        guard seen.newUnlockSecret.count == 32 else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        vaultSecret = seen.newUnlockSecret
        try reply(m.type, try rotated() + "}", re: m.id)
    }

    /// `vault.delete` in vettid-vault's order: the phrase (`bad_request`), the PIN (`bad_pin`), then the blob
    /// (`stale_credential`) and the password (`bad_password`). Then `{}`, `device.unlinked{vault_deleted}`, and the vault
    /// is gone. Callers hold ``cond``.
    func vaultDelete(_ m: Inner, _ body: JsonObject) throws {
        guard let p = try opened(m, body) else { return }
        let seen = DeleteSeen(
            confirm: try body.optString("confirm"), pin: (try? p.string("pin")) ?? "", password: (try? p.string("password")) ?? ""
        )
        deletesValue.append(seen)
        guard seen.confirm == Self.deletePhrase else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        guard seen.pin == vaultPin else {
            pinFailures += 1
            return try reply(m.type, "{}", re: m.id, error: "bad_pin")
        }
        pinFailures = 0
        guard try body.optString("credential") == Self.blob(credentialVersion) else {
            return try reply(m.type, "{}", re: m.id, error: "stale_credential")
        }
        guard seen.password == vaultPassword else {
            passwordFailures += 1
            return try reply(m.type, "{}", re: m.id, error: "bad_password")
        }
        try reply(m.type, "{}", re: m.id)
        try reply("device.unlinked", #"{"reason":"vault_deleted"}"#)
        vaultDeletedValue = true
        vaultOpen = false
    }
}
#endif
