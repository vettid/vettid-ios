import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDVault

// The staging time scale (STAGING-TIME-SCALE §5.2; VAULT-MESSAGING 0.43.0 §11.10.9; IOS-PLAN §6.6): learnt from the
// verified descriptor of the vault's instance (an enrollment, the release check before the PIN, an unlock) and from
// `vault.status`, and stored per vault in the account record (``LocalAccount/timeScale``). A transfer bundle carries it
// too: the transfer to this phone (I3) stores ``InviteBundle/timeScaleOrReal`` with the vault it brings, after
// ``TimeScalePolicy/check(_:)``. The app's own waits (``TimeScales``) divide by it when each starts.
extension VaultManager {
    /// The scale of the verified instance this phone sealed to, for the record of [rec] (a reset since drops it). The
    /// alternate channel already refused a scale this build does not accept (``TimeScalePolicy``).
    func learnTimeScale(_ scale: UInt64, since rec: Int) {
        guard scale >= TimeScale.real else { return }
        _ = try? record.update(since: rec) { $0.timeScale = scale }
    }

    /// `vault.status`'s `time_scale` (absent: a release before it, 1), for the record of [rec] (the one the session was
    /// opened for). A value this build does not accept is not stored (chosen; not in the spec: the descriptor's check
    /// already refuses such an instance before any unlock).
    func learnTimeScale(status st: VaultStatusInfo, since rec: Int) {
        let scale = UInt64(clamping: st.timeScale ?? Int64(TimeScale.real))
        guard config.trust.timeScales.accepts(scale) else { return }
        learnTimeScale(scale, since: rec)
    }
}
