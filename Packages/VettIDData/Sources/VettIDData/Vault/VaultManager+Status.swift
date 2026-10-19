import Foundation
import VettIDAltChan
import VettIDVault

// Settings → Vault status and Settings → Attestation (IOS-PLAN §8 I1.8).
extension VaultManager {
    /// Vault status: the member API's advisory status (`GET /api/vault/status`) and, while the vault is open, its own
    /// `vault.status` (VAULT-MESSAGING §10.2). vettid-android also reads its own `device.list` entry for the signer line (VAULT-MESSAGING §11.7.1); an
    /// iPhone has no signer (App Attest reports none), and Settings shows "Installed from" from the build instead
    /// (IOS-PLAN ID15), so the list is not read. The recovery counter's "unavailable for a day" clock comes with the
    /// recovery screens (I3); until then ``RecoveryStatusView/unknownForADay`` stays false. Mirrors vettid-android
    /// `VaultManager.overview`.
    public func overview() async throws -> VaultOverview {
        try await guarded {
            let s = try await openSession()
            let member = try await vaultStatus()
            let own = phase == .unlocked ? try await openStatus(s) : nil
            return Self.overview(
                member: member, own: own, deviceVault: s.device.vaultID, lastRelease: s.device.altState.releaseNumber,
                recoveryOffered: ReleasePath.recoveryOffered(record.value.capabilities)
            )
        }
    }

    /// The vault's own `vault.status`, or nil when it did not answer (the network, no answer in time): the screen then
    /// shows what the member API said. Any other failure is the screen's (as vettid-android drops only an `IOException`).
    private func openStatus(_ s: VaultSession) async throws -> VaultStatusInfo? {
        do {
            let st = try await openApi(s).status()
            learnTimeScale(status: st)
            return st
        } catch {
            let mapped = VaultFailures.map(error)
            if let f = mapped as? VaultFailure, f.kind == .network || f.kind == .noResponse { return nil }
            throw mapped
        }
    }

    nonisolated static func overview(
        member st: VaultStatus?,
        own vs: VaultStatusInfo?,
        deviceVault: String?,
        lastRelease: UInt64,
        recoveryOffered: Bool
    ) -> VaultOverview {
        VaultOverview(
            vaultID: st?.vaultID ?? deviceVault,
            state: st?.state,
            release: st?.release.map {
                ReleaseInfoView(number: $0.number, status: $0.status, endsAt: $0.endsAt, newestActive: $0.newestActive, notice: $0.notice)
            },
            lastRelease: lastRelease,
            recoveryState: st?.recoveryState,
            provisional: vs?.provisional,
            devices: vs?.devices,
            connections: vs?.connections,
            signer: nil,
            recovery: vs?.recovery.flatMap(recoveryView),
            recoveryOffered: recoveryOffered
        )
    }

    /// `vault.status`'s `recovery` for the screen: `unknown` when the vault did not say its state.
    nonisolated static func recoveryView(_ r: RecoveryStatus) -> RecoveryStatusView? {
        RecoveryStatusView(
            state: r.state ?? "unknown", used: r.attempts?.used, counterUnavailable: r.counter == counterUnavailable
        )
    }

    nonisolated static let counterUnavailable = "unavailable"

    /// Settings → Attestation on an iPhone: whether the vault accepted this iPhone's App Attest key (the phone is paired
    /// with it), and the enclave release this phone last verified (VAULT-MESSAGING §11.2), its PCR0 shortened to 16 hex digits in groups
    /// of four as vettid-android shows it. Mirrors vettid-android `VaultManager.attestationInfo`, with the iPhone's device
    /// side (``AppAttestInfo``).
    public func attestationInfo() async throws -> AttestationInfo {
        try await guarded {
            let device = try await storedSession()?.device
            let alt = device?.altState
            return AttestationInfo.iPhone(
                environment: config.environment,
                appAttest: AppAttestInfo(accepted: device?.deviceID != nil),
                lastRelease: alt?.releaseNumber ?? 0,
                lastReleaseFingerprint: alt.flatMap { Self.fingerprint($0.release) }
            )
        }
    }

    /// The first 16 hex digits of a release's PCR0, in groups of four; nil for none.
    nonisolated static func fingerprint(_ pcr0: String) -> String? {
        guard !pcr0.isEmpty else { return nil }
        let head = Array(pcr0.prefix(16))
        return stride(from: 0, to: head.count, by: 4).map { String(head[$0..<min($0 + 4, head.count)]) }.joined(separator: " ")
    }
}
