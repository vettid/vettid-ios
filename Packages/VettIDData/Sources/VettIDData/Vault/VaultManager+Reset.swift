import Foundation
import VettIDVault

// New credential (`credential.reset`, VAULT-MESSAGING §3.5.5) sent and decided as a change is (0.48.0 §11.14.9 "A lost
// answer to `credential.reset`"; ANDROID-PLAN 0.1.51 "A lost answer to New credential"; IOS-PLAN 0.1.9 §6.3). A reset
// that applied without its answer would leave this phone holding a blob of the replaced credential, which the vault takes
// for a clone at the next credential operation (§3.5.9), so the reset is never sent again with a new request:
//
// - Before the send: nothing else in flight, every earlier request settled, a renew whose answer was lost decided, and
//   the `credential.version` pre-check, whose `key` is stored as the held key with the unresolved change (type
//   `credential.reset`, inner id, blob version, `exp`; no secret). An answer without a `key` refuses the reset with
//   nothing sent (the "earlier request" text).
// - While it is unresolved, the gate refuses every other credential operation at once (``decideFirst(carriesPin:)``,
//   with the reset's "still checking" text). The unlock is not affected: a reset changes neither the PIN nor the phone's
//   secret.
// - Deciding (``decideReset``): the same request again while `exp` has not passed, then `credential.version`: another
//   `key` than the held one, or a lower `version`, is applied (the latest blob fetched, kept and acknowledged, UTKs
//   topped up); the same `key` and `version` stamped more than a minute after `exp` is not applied; the same earlier is
//   undecided; anything else ends the check without a decision.
// - Its own answer decides by itself: the new blob is success; every refusal, `stale_credential` included (the blob
//   fetched, the typed secrets not sent again), is not applied.
extension VaultManager {
    /// `credential.reset` (§3.5.5) by the holder: the PIN, the current password and the new one. Every critical item is
    /// destroyed. The PIN and the password are checked as an owner check is, a wrong one counting as a failed check
    /// (§3.6.1), after which the owner check's state is read again; a success starts the owner-check clock afresh. As
    /// before a PIN change, a renew on its way refuses it at once, and a renew whose answer was lost is decided first
    /// (VAULT-MESSAGING 0.46.0 §11.14.9 step 1): the reset replaces the DEK under the phone's current secret. No answer is
    /// not a failure: the reset is decided (``changing(_:_:)``), and refused as ``FailureKind/changeUnresolved`` while
    /// undecided; decided not applied, ``codeChangeNotApplied``.
    public func newCredential(pin: String, password: String, newPassword: String) async throws {
        try await guarded {
            if phoneSecrets.anyInFlight { throw VaultFailure(.busy, code: "change_in_flight") }
            try await decideFirst(carriesPin: true)
            let s = try await openSession()
            let api = try openApi(s)
            // A change or a renew that goes out from here on refuses this one (VAULT-MESSAGING 0.47.0 §11.14.9 step 2).
            let since = s.device.secretsSent
            try await settleRenews(api)
            let box = MarkerBox()
            do {
                try await changing(box) {
                    // Stored once the request is fixed, after the pre-check (0.48.0 step 1), with its key.
                    try await api.credentialReset(
                        pin: pin, password: password, newPassword: newPassword, since: since
                    ) { @MainActor change in
                        let marker = UnresolvedChange(
                            type: .reset, id: change.id, version: change.version, exp: change.exp, heldKey: change.key
                        )
                        try self.phoneSecrets.setUnresolved(marker)
                        box.marker = marker
                    }
                    if let m = box.marker { try? phoneSecrets.clearUnresolved(id: m.id) }
                }
            } catch let e as VaultOpError where e.code == OwnerCheckManager.codeBadPin || e.code == OwnerCheckManager.codeBadPassword {
                ownerChecks.onOpened()
                throw e
            }
            resetApplied()
            await refreshAlarm(api)
        }
    }

    /// The decision of an unresolved reset by `credential.version` (VAULT-MESSAGING 0.48.0 §11.14.9 "A lost answer to
    /// `credential.reset`" step 3). Of the requests this app could have sent, only a reset or a rotation changes the key,
    /// and the gate refused the rotation. An answer without a `key` ends the check (chosen; not in the spec, which names no
    /// such answer: vettid-vault's always carries one). The same key with another version: the latest blob is kept first,
    /// as for a change (chosen; not in the spec).
    func decideReset(_ marker: UnresolvedChange, _ v: StampedCredentialInfo, _ api: VaultApi, _ gen: Int) async {
        let info = v.info
        guard info.exists, let version = info.version, info.alarm?.alarmID == nil, let key = info.key, !key.isEmpty else {
            return ended(marker, info)
        }
        if marker.heldKey.map({ $0 != key }) == true || version < marker.version {
            return await applied(marker, api, answer: nil, gen)
        }
        guard version == marker.version, marker.heldKey != nil else {
            if await endedByForbidden(marker, gen, { try await api.credentialFetch() }) { return }
            guard stillUnresolved(marker, gen) else { return }
            return ended(marker, info)
        }
        if pastDecision(marker, v.ts) { return notApplied(marker) }
        undecided(marker, reachable: true)
    }

    /// A reset applied, by its own answer or by the decision: the unlock window is over and any alarm resolved (the vault
    /// ends both with the old credential), and the owner check's state is read again (its clock started afresh). The
    /// critical items went with the old credential; this app keeps no copy of them to drop.
    func resetApplied() {
        unlockWindow = nil
        alarm = nil
        ownerChecks.onOpened()
    }
}
