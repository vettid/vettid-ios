import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDVault

extension VaultManager {
    /// The sealed open, posted. Its entry in the history of the identity's opens is written, unanswered, before it is posted (in
    /// ``VaultDevice/prepareRecoveryOpen(userGuid:pin:password:unlockSecret:enclave:manifest:attester:)``); a save that fails posts
    /// nothing. A post failure of any kind keeps the entry, the POST's own `4xx` too (a re-sent POST can be queued), and nothing
    /// after the post may remove it (IOS-PLAN 0.1.35 §4.9). The answer updates the entry of this open only
    /// (``noteOpenAnswer(_:device:id:)``).
    func postRecoveryOpen(
        _ s: VaultSession, pin: String, password: String, secret: SecretBox, rec: Int
    ) async throws -> RecoveryOpen.Result {
        await convertLegacyUnanswered(s.device)
        let (vaultID, guid) = (record.value.vaultID, record.value.userGuid)
        let attester = config.attester
        // A readable `attestation` tries the next key of the identity (a register sent again attested a key of its own). Each open
        // built has its entry, and each answer is written to its own entry before the next key is tried: an `attestation` that used
        // no attempt settles that open (chosen; not in the spec; owner decision 2026-10-26, spec question raised).
        return try await s.alt.recoveryOpen(
            vaultID: vaultID, attester: attester,
            build: { [weak self] e, m in
                // IOS-PLAN ID8: this phone registered with release R; an instance without it is refused, nothing sent.
                try ReleasePath.requireR(e.descriptor.capabilities)
                await self?.learnTimeScale(e.descriptor.timeScale, since: rec)
                return try await s.device.prepareRecoveryOpen(
                    userGuid: guid, pin: pin, password: password, unlockSecret: secret.value, enclave: e, manifest: m,
                    attester: attester
                )
            },
            open: { [weak self] raw, rid in
                let r = try await s.device.openRecoveryOpenResult(raw, requestID: rid)
                await self?.noteOpenAnswer(r, device: s.device, id: rid)
                return r
            },
            onSent: { [weak self] in await self?.noteRecoveryOpenSent(since: rec) }
        )
    }
}
