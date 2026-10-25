import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDVault

extension VaultManager {
    /// The sealed open, posted. Its entry in the history of the identity's opens is written, unanswered, before it is posted (in
    /// ``VaultDevice/prepareRecoveryOpen(userGuid:pin:password:unlockSecret:enclave:manifest:attester:)``): a response that is lost
    /// after the member API took it leaves it so. A `4xx` to the POST itself is a definite non-acceptance. The answer updates the
    /// entry of this open only (``noteOpenAnswer(_:device:id:)``).
    func postRecoveryOpen(
        _ s: VaultSession, pin: String, password: String, secret: SecretBox, rec: Int
    ) async throws -> RecoveryOpen.Result {
        let (vaultID, guid) = (record.value.vaultID, record.value.userGuid)
        let attester = config.attester
        let sent = SentFlag()
        do {
            let r = try await s.alt.recoveryOpen(
                vaultID: vaultID,
                build: { [weak self] e, m in
                    // IOS-PLAN ID8: this phone registered with release R; an instance without it is refused, nothing sent.
                    try ReleasePath.requireR(e.descriptor.capabilities)
                    await self?.learnTimeScale(e.descriptor.timeScale, since: rec)
                    return try await s.device.prepareRecoveryOpen(
                        userGuid: guid, pin: pin, password: password, unlockSecret: secret.value, enclave: e, manifest: m,
                        attester: attester
                    )
                },
                open: { raw, rid in try await s.device.openRecoveryOpenResult(raw, requestID: rid) },
                onSent: { [weak self] in
                    sent.set()
                    await self?.noteRecoveryOpenSent(since: rec)
                }
            )
            await noteOpenAnswer(r, device: s.device, id: nil)
            return r
        } catch let e as MemberApiError where !sent.value && (400..<500).contains(e.status) {
            try? await s.device.markRecoveryOpen(nil, .refused("not_accepted"))
            throw e
        }
    }
}
