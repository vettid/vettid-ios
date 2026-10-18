import Foundation

/// The rules around "Finish the move" and leaving onboarding (release R, VAULT-MESSAGING §11.14.10). Mirrors
/// vettid-android `FinishSetupGate`.
enum FinishSetupGate {
    /// Onboarding may give way to the open app only from ``SetupStage/finishing``, with no lock pending and no "Finish
    /// the move" running: otherwise the shell would show over a vault that is (or is about to be) locked.
    static func allows(_ phase: AppPhase, lockPending: Bool, finishingMove: Bool) -> Bool {
        phase == .setup(.finishing) && !lockPending && !finishingMove
    }

    /// What the unlock screen says after a "Finish the move" that did not open the vault; nil after a success.
    static func failure(of r: UnlockAttempt) -> FailureKind? {
        switch r {
        case .success: nil
        case .badPin: .badPin
        case .backoff: .backoff
        case .failed(let kind, _, _): kind
        default: .other
        }
    }
}
