import Foundation
import VettIDVault

// The rest of the credential screen (VAULT-MESSAGING §3.5.5, §3.5.9): the rotation, the answer to a clone alarm, and the
// offer to rotate after a PIN or password change (ANDROID-PLAN "Transfer"). Mirrors vettid-android `VaultManager.rotate`,
// `confirmAlarm` and its rotate offer.
//
// The rotation is not a change of §11.14.9 "A lost answer": no unresolved change is stored and no version pre-check runs.
// It is a credential operation, so it passes the gate first (``decideFirst(carriesPin:)``, and again under the credential
// lock): refused at once while a change is unresolved. A new credential is sent and decided as a change is
// (VAULT-MESSAGING 0.48.0 §11.14.9 "A lost answer to `credential.reset`", VaultManager+Reset.swift).
extension VaultManager {
    /// `credential.rotate` (§3.5.5): a new credential key with the password. On success the rotate offer is taken up, the
    /// unlock window is over (the vault ends it) and a clone alarm is resolved (§3.5.9: the forced rotation). A wrong
    /// password counts only in the password backoff (§3.6.1).
    ///
    /// The forced rotation (§3.5.9): during an alarm the vault answers a blob of the holder's that is not its latest with
    /// the freeze code, not `stale_credential` (a phone restored from a backup holds an older one). So before a rotation
    /// while an alarm is open, and once more when a rotation is answered `rotation_required` or `credential_frozen`, the
    /// version the vault holds is asked (`credential.version`), and when it is not the one of this phone's blob the latest
    /// blob is fetched (`credential.get`, allowed in `rotation_required`) and kept; after such a refusal the rotation is
    /// sent once more.
    public func rotate(password: String) async throws {
        try await guarded {
            try await decideFirst()
            let rec = record.generation
            let s = try await openSession()
            let api = try openApi(s)
            if alarm != nil { _ = await fetchedLatestBlob(api, s.device) }
            do {
                try await api.credentialRotate(password: password)
            } catch let e as VaultOpError where e.code == Self.codeRotationRequired || e.code == Self.codeCredentialFrozen {
                guard await fetchedLatestBlob(api, s.device) else { throw e }
                try await api.credentialRotate(password: password)
            }
            setRotateOffer(false, since: rec)
            unlockWindow = nil
            // The vault resolves any open alarm with the rotation; its own word follows (`sync.event`, the version).
            alarm = nil
            await refreshAlarm(api)
        }
    }

    nonisolated static let codeRotationRequired = "rotation_required"
    nonisolated static let codeCredentialFrozen = "credential_frozen"

    /// Whether the latest blob was fetched and kept because the vault's version is not the one of this phone's blob. The
    /// alarm is taken from the same answer. False when the versions match, or when the vault could not be asked or did
    /// not give its blob.
    private func fetchedLatestBlob(_ api: VaultApi, _ device: VaultDevice) async -> Bool {
        guard let info = try? await api.credentialVersion() else { return false }
        keepAlarm(info)
        guard info.exists, let v = info.version, v != device.credentialVersion else { return false }
        do {
            try await api.credentialFetch()
        } catch {
            return false
        }
        return device.credentialVersion == v
    }

    /// `credential.alarm.confirm` (§3.5.9): the answer to the open alarm, [mine] true for "that was me". Either way the
    /// alarm moves to `rotation_required` and the rotation follows. Not a credential operation: allowed while a change is
    /// unresolved, and during a hold (§3.6.3). Without an open alarm: ``FailureKind/notFound``; when the vault answers
    /// `not_found` (the alarm was resolved or replaced meanwhile) the alarm is read again.
    public func confirmAlarm(mine: Bool) async throws {
        try await guarded {
            guard let a = alarm else { throw VaultFailure(.notFound) }
            let api = try openApi(try await openSession())
            let state: String?
            do {
                state = try await api.credentialAlarmConfirm(alarmID: a.alarmID, mine: mine)
            } catch let e as VaultOpError where e.code == "not_found" {
                await refreshAlarm(api)
                throw e
            }
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
    func refreshAlarm(_ api: VaultApi) async {
        guard let info = try? await api.credentialVersion() else { return }
        keepAlarm(info)
    }

    /// The alarm of a `credential.version` answer.
    private func keepAlarm(_ info: CredentialInfo) {
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
