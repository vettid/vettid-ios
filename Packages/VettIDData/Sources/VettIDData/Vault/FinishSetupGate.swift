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
    static func failure(of r: UnlockAttempt) -> MoveFailure? {
        switch r {
        case .success: nil
        case .badPin: MoveFailure(.badPin)
        case .backoff: MoveFailure(.backoff)
        case .failed(let kind, let code, _): MoveFailure(kind, code: code)
        default: MoveFailure(.other)
        }
    }
}

/// Why a "Finish the move" did not open the vault: the kind, and the code that tells `no_user_guid` from the unlock's own
/// guard apart (``noUserGuid``). Mirrors vettid-android `MoveFailure`.
public struct MoveFailure: Equatable, Sendable {
    public let kind: FailureKind
    public let code: String?

    public init(_ kind: FailureKind, code: String? = nil) {
        self.kind = kind
        self.code = code
    }

    /// No usable `user_guid` on this phone (``UnlockAttempt/isNoUserGuid(_:_:)``): it can never unlock.
    public var noUserGuid: Bool { UnlockAttempt.isNoUserGuid(kind, code) }
}
