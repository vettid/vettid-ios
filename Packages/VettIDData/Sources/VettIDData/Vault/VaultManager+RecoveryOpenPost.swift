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
        let built = BuiltOpen()
        let r = try await s.alt.recoveryOpen(
            vaultID: vaultID,
            build: { [weak self] e, m in
                // IOS-PLAN ID8: this phone registered with release R; an instance without it is refused, nothing sent.
                try ReleasePath.requireR(e.descriptor.capabilities)
                await self?.learnTimeScale(e.descriptor.timeScale, since: rec)
                let req = try await s.device.prepareRecoveryOpen(
                    userGuid: guid, pin: pin, password: password, unlockSecret: secret.value, enclave: e, manifest: m,
                    attester: attester
                )
                built.id = req.requestID
                return req
            },
            open: { raw, rid in try await s.device.openRecoveryOpenResult(raw, requestID: rid) },
            onSent: { [weak self] in await self?.noteRecoveryOpenSent(since: rec) }
        )
        if let id = built.id { await noteOpenAnswer(r, device: s.device, id: id) }
        return r
    }
}

/// The request id of the open `build` returned (nil until it did).
final class BuiltOpen: @unchecked Sendable {
    private let lock = NSLock()
    private var request: String?

    var id: String? {
        get { lock.withLock { request } }
        set { lock.withLock { request = newValue } }
    }
}
