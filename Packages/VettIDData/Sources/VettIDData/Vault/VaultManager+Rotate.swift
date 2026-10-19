import Foundation
import VettIDVault

// The rest of the credential screen (VAULT-MESSAGING §3.5.5, §3.5.9): the rotation, a new credential and the answer to a
// clone alarm, and the offer to rotate after a PIN or password change (ANDROID-PLAN "Transfer"). Mirrors vettid-android
// `VaultManager.rotate`, `newCredential`, `confirmAlarm` and its rotate offer.
//
// Neither the rotation nor a new credential is a change of §11.14.9 "A lost answer", which covers `pin.change`,
// `credential.password.change` and `vault.secret.renew` only (it says `credential.reset` is not covered): no unresolved
// change is stored and no version pre-check runs. Both are credential operations, so each passes the gate first
// (``decideFirst(carriesPin:)``, and again under the credential lock): refused at once while a change is unresolved, and
// a new credential, which carries the PIN, also while the PIN is uncertain (step 3).
extension VaultManager {
    /// `credential.rotate` (§3.5.5): a new credential key with the password. On success the rotate offer is taken up, the
    /// unlock window is over (the vault ends it) and a clone alarm is resolved (§3.5.9: the forced rotation). A wrong
    /// password counts only in the password backoff (§3.6.1).
    public func rotate(password: String) async throws {
        try await guarded {
            try await decideFirst()
            let since = record.generation
            let api = try openApi(try await openSession())
            try await api.credentialRotate(password: password)
            setRotateOffer(false, since: since)
            unlockWindow = nil
            // The vault resolves any open alarm with the rotation; its own word follows (`sync.event`, the version).
            alarm = nil
            await refreshAlarm(api)
        }
    }

    /// `credential.reset` (§3.5.5) by the holder: the PIN, the current password and the new one. Every critical item is
    /// destroyed. The PIN and the password are checked as an owner check is, a wrong one counting as a failed check
    /// (§3.6.1), after which the owner check's state is read again; a success starts the owner-check clock afresh. A
    /// `stale_credential` is not sent again with the same secrets (``VaultApi/credentialReset(pin:password:newPassword:)``).
    public func newCredential(pin: String, password: String, newPassword: String) async throws {
        try await guarded {
            try await decideFirst(carriesPin: true)
            let api = try openApi(try await openSession())
            do {
                try await api.credentialReset(pin: pin, password: password, newPassword: newPassword)
            } catch let e as VaultOpError where e.code == OwnerCheckManager.codeBadPin || e.code == OwnerCheckManager.codeBadPassword {
                ownerChecks.onOpened()
                throw e
            }
            unlockWindow = nil
            alarm = nil
            await refreshAlarm(api)
            ownerChecks.onOpened()
        }
    }

    /// `credential.alarm.confirm` (§3.5.9): the answer to the open alarm, [mine] true for "that was me". Either way the
    /// alarm moves to `rotation_required` and the rotation follows. Not a credential operation: allowed while a change is
    /// unresolved, and during a hold (§3.6.3). Without an open alarm: ``FailureKind/notFound``.
    public func confirmAlarm(mine: Bool) async throws {
        try await guarded {
            guard let a = alarm else { throw VaultFailure(.notFound) }
            let api = try openApi(try await openSession())
            let state = try await api.credentialAlarmConfirm(alarmID: a.alarmID, mine: mine)
            if alarm?.alarmID == a.alarmID { alarm?.state = state ?? CredentialAlarm.stateRotationRequired }
        }
    }

    /// The member put the offer away; for whatever record is current.
    public func dismissRotateOffer() { setRotateOffer(false, since: record.generation) }

    /// The rotate offer, kept in the account record of [since] (a write for a record that was reset since is dropped). A
    /// write that fails leaves the offer as it was (chosen; not in the spec).
    func setRotateOffer(_ on: Bool, since: Int) {
        _ = try? record.update(since: since) { $0.rotateOffer = on }
    }

    /// The alarm as `credential.version` shows it now (the `presenter` of the alert kept for the same alarm); unchanged
    /// when the vault does not answer.
    private func refreshAlarm(_ api: VaultApi) async {
        guard let info = try? await api.credentialVersion() else { return }
        alarm = info.alarm.flatMap { a in
            a.alarmID.map { id in
                CredentialAlarm(
                    alarmID: id, state: a.state ?? CredentialAlarm.stateFrozen, at: a.at,
                    presenter: alarm?.alarmID == id ? alarm?.presenter : nil
                )
            }
        }
    }
}
