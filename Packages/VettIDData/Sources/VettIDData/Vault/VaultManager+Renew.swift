import Foundation
import VettIDVault

// New phone secret (release R, VAULT-MESSAGING §11.14.9 `vault.secret.renew`; IOS-PLAN §6.3) and the prompt for one
// after the earlier-secret step opened the vault (§6.3 item 5). Mirrors vettid-android `VaultManager.renewPhoneSecret`.
//
// A lost answer (VAULT-MESSAGING 0.46.0 §11.14.9 step 1, "A renew is settled before a PIN change"): the next-epoch
// record is written as a candidate before the request is built, with the request's inner id, `exp` and blob version
// (``PhoneRecords/SentRequest``); no answer leaves it a candidate with that request; a retry of the same operation sends
// the same secret. Before a PIN change the request is decided by `credential.version` with step 3's table
// (``settleRenews(_:)``): one above, applied (the candidate made current); the same version stamped more than a minute
// after `exp`, not applied; anything else cannot be decided, and the PIN change is refused with a lock and unlock to
// settle it (the PIN has not changed, so that unlock costs nothing). Any refusal of the renew's own request,
// `stale_credential` included, means it did not apply (VAULT-MESSAGING: pending spec PR for vettid/vettid.org#347). A
// renew is a credential operation all the same: refused while a change is unresolved or on its way (step 2), and sent
// after the same checks as a change, its record and request stored only after them
// (``VaultApi/secretRenew(pin:password:onMarker:onAnswered:)``).
extension VaultManager {
    /// `vault.secret.renew` (§11.14.9): a new phone secret, the PIN unchanged. The next epoch's record is written before
    /// the request is built (IOS-PLAN §6.3 item 1) and becomes current with the vault's answer; a record that cannot be
    /// made current then is a success all the same (the next unlock's `device_secret` confirms it). A retry after a
    /// refusal or a lost answer reuses the record (item 2). Refused for a phone without a phone secret, while a change of
    /// PIN or password is unresolved or on its way, and while four changes are unconfirmed.
    public func renewPhoneSecret(pin: String, password: String) async throws {
        try await guarded {
            guard phoneSecrets.inUse else { throw VaultFailure(.notSupported, code: Self.codeNoPhoneSecret) }
            // It carries the PIN: refused while the PIN is uncertain too (§11.14.9 step 3).
            try await decideFirst(carriesPin: true)
            let api = try openApi(try await openSession())
            try await refreshedOnce {
                // No await from here to the send's start: a second renew, or a PIN change, is refused by the records' slot.
                let operation = try renewOperationID()
                let state = RenewSend()
                do {
                    defer { phoneSecrets.endChange(operation: operation) }
                    try await api.secretRenew(pin: pin, password: password, onMarker: { @MainActor change in
                        // The record and its request, once the request is fixed after the checks (0.46.0 step 1).
                        let sent = PhoneRecords.SentRequest(id: change.id, version: change.version)
                        let next = try self.phoneSecrets.beginChange(operation: operation, exp: change.exp, sent: sent)
                        state.sentID = change.id
                        return next
                    }, onAnswered: { @MainActor in
                        // Its own `ok`: the vault holds the new secret, whatever happens to the rest of the answer.
                        state.answered = true
                        self.renewOperation = nil
                        _ = try? self.phoneSecrets.confirmChange(operation: operation)
                    })
                } catch {
                    try renewFailed(error, operation, state)
                }
            }
            renewSecretSuggested = false
        }
    }

    /// A renew that failed: no answer once it may have gone out keeps its request for ``settleRenews(_:)``; its own
    /// refusal (`stale_credential` included), or a failure before anything was sent, leaves nothing to decide; after its
    /// own `ok` nothing is undone (VAULT-MESSAGING: pending spec PR for vettid/vettid.org#347).
    private func renewFailed(_ error: any Error, _ operation: String, _ state: RenewSend) throws -> Never {
        switch error {
        case is RequestUnanswered: throw VaultFailure(.noResponse)
        case is CancellationError: throw CancellationError()
        default: break
        }
        let ownRefusal = (error as? VaultOpError).map { $0.type == VaultApi.typeSecretRenew } ?? true
        if !state.answered, ownRefusal, let id = state.sentID { try? phoneSecrets.clearSent(operation: operation, id: id) }
        throw error
    }

    /// Before a PIN change (VAULT-MESSAGING 0.46.0 §11.14.9 step 1): every renew whose answer was lost is decided first,
    /// once every credential request of this phone is settled, by `credential.version`. Applied: the latest blob fetched
    /// and the renew's record made current. Not applied (the same version, stamped more than a minute after its `exp`):
    /// nothing left to decide. Still possible: refused with the "earlier request" text (``FailureKind/credentialUnsettled``).
    /// Undecidable: refused (``FailureKind/renewUnconfirmed``) until a lock and unlock confirms one record.
    func settleRenews(_ api: VaultApi) async throws {
        let pending = try phoneSecrets.records().candidates.filter { $0.sent != nil }
        guard !pending.isEmpty else { return }
        guard await api.credentialAwaitSettled() else {
            throw VaultFailure(.credentialUnsettled, code: VaultFailures.codeCredentialUnsettled)
        }
        let v = try await api.credentialVersionStamped()
        for c in pending.reversed() {
            guard let sent = c.sent, let version = v.info.version, v.info.exists, v.info.alarm?.alarmID == nil else {
                throw VaultFailure(.renewUnconfirmed, code: Self.codeRenewUnconfirmed)
            }
            if version == sent.version + 1 {
                try await api.credentialFetch()
                try? await api.topUpUTKs()
                if renewOperation == c.operation { renewOperation = nil }
                guard (try? phoneSecrets.confirmChange(operation: c.operation)) == true else {
                    throw VaultFailure(.renewUnconfirmed, code: Self.codeRenewUnconfirmed)
                }
                return
            }
            guard version == sent.version else { throw VaultFailure(.renewUnconfirmed, code: Self.codeRenewUnconfirmed) }
            guard let exp = c.exp, v.ts > exp.addingTimeInterval(Self.decidedAfterExp) else {
                throw VaultFailure(.credentialUnsettled, code: VaultFailures.codeCredentialUnsettled)
            }
            try phoneSecrets.clearSent(operation: c.operation, id: sent.id)
        }
    }

    /// The code of a PIN change refused while a renew whose answer was lost cannot be decided.
    public nonisolated static let codeRenewUnconfirmed = "renew_unconfirmed"

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

/// What one renew request came to: its request stored ([sentID]) and its own `ok` ([answered]).
@MainActor
final class RenewSend {
    var sentID: String?
    var answered = false
}
