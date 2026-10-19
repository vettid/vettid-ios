import Foundation
import VettIDVault

// New phone secret (release R, VAULT-MESSAGING §11.14.9 `vault.secret.renew`; IOS-PLAN §6.3) and the prompt for one
// after the earlier-secret step opened the vault (§6.3 item 5). Mirrors vettid-android `VaultManager.renewPhoneSecret`.
//
// A lost answer: §11.14.9 "A lost answer" decides `pin.change` and `credential.password.change`, whose retry would spend
// an attempt; a renew "has the same shape, but a retry with the same PIN and password spends nothing; the app MAY decide
// it the same way". The iPhone app does not: a renew follows IOS-PLAN §6.3's own rules. Its next-epoch record is written
// as a candidate before the request is built; no answer leaves it a candidate; a retry of the same operation sends the
// same secret; an unlock answered `device_secret` with the current record tries the candidate (step 5 with the previous
// PIN while a PIN change is unresolved). The request carries an `exp` (chosen; not in the spec), stored with the record:
// an unlock's `ok` with the current record keeps the candidate until a minute after it, since a copy waiting in a locked
// vault's mailbox may still apply after that unlock. A renew is a credential operation all the same: refused while a
// change is unresolved or on its way (step 2).
extension VaultManager {
    /// `vault.secret.renew` (§11.14.9): a new phone secret, the PIN unchanged. The next epoch's record is written before
    /// the request is built (IOS-PLAN §6.3 item 1) and becomes current with the vault's answer; a record that cannot be
    /// made current then is a success all the same (the next unlock's `device_secret` confirms it). A retry after a
    /// refusal or a lost answer reuses the record (item 2). Refused for a phone without a phone secret, while a change of
    /// PIN or password is unresolved or on its way, and while four changes are unconfirmed.
    public func renewPhoneSecret(pin: String, password: String) async throws {
        try await guarded {
            guard phoneSecrets.inUse else { throw VaultFailure(.notSupported, code: Self.codeNoPhoneSecret) }
            try await decideFirst()
            let api = try openApi(try await openSession())
            // Stored with the record (chosen; not in the spec): until a minute after it, a copy waiting in a locked vault's
            // mailbox may still apply, and an unlock's `ok` with the current record keeps the record a candidate.
            let exp = try await api.requestExp()
            // No await from here to the send's start: a second renew, or a PIN change, is refused by the records' slot.
            let operation = try renewOperationID()
            _ = try await phoneSecrets.change(operation: operation, exp: exp, send: { next in
                try await api.secretRenew(pin: pin, password: password, newUnlockSecret: next, exp: exp)
            }, confirmed: { _ in false })
            // The vault holds the new secret: a new renew makes a new record, whether or not this one is current yet.
            renewOperation = nil
            _ = try? phoneSecrets.confirmChange(operation: operation)
            renewSecretSuggested = false
        }
    }

    /// The prompt for a new phone secret after the earlier-secret step: the member chose not to now.
    public func dismissRenewSuggestion() { renewSecretSuggested = false }

    /// (iPhone, IOS-PLAN §6.3 item 5) The earlier-secret step opened the vault: ``renewSecretSuggested`` asks the shell
    /// for the prompt. The History entry on the phone comes with History (IOS-PLAN §8 I2).
    func earlierSecretRestored() { renewSecretSuggested = true }

    /// The operation of this renew: the one still unconfirmed (a retry reuses its record), else a new one. Refused while
    /// that operation is on its way.
    private func renewOperationID() throws -> String {
        if let op = renewOperation {
            if phoneSecrets.inFlight(operation: op) { throw VaultFailure(.busy, code: "change_in_flight") }
            // An operation whose record is no longer a candidate (an unlock confirmed or replaced it) is over.
            if try !phoneSecrets.records().candidates.contains(where: { $0.operation == op }) { renewOperation = nil }
        }
        let operation = renewOperation ?? "\(VaultApi.typeSecretRenew)-\(UUID().uuidString)"
        renewOperation = operation
        return operation
    }
}
