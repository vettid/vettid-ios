import Testing
@testable import VettIDData

/// Leaving onboarding never shows the shell over a locked vault; a failed "Finish the move" says why (release R).
/// Mirrors vettid-android `FinishSetupGateTest`.
@Suite struct FinishSetupGateTests {
    private let finishing = AppPhase.setup(.finishing)

    @Test func onlyFromFinishingWithNothingPending() {
        #expect(FinishSetupGate.allows(finishing, lockPending: false, finishingMove: false))
        #expect(!FinishSetupGate.allows(finishing, lockPending: true, finishingMove: false), "a lock pending")
        #expect(!FinishSetupGate.allows(finishing, lockPending: false, finishingMove: true), "Finish the move running")
        #expect(!FinishSetupGate.allows(.locked, lockPending: false, finishingMove: false))
        #expect(!FinishSetupGate.allows(.setup(.needsCredential), lockPending: false, finishingMove: false))
    }

    @Test func theFailureOfAMoveThatDidNotFinish() {
        #expect(FinishSetupGate.failure(of: .success) == nil)
        #expect(FinishSetupGate.failure(of: .badPin(retryAfterSeconds: 0))?.kind == .badPin)
        #expect(FinishSetupGate.failure(of: .backoff(retryAfterSeconds: 30))?.kind == .backoff)
        #expect(
            FinishSetupGate.failure(of: .failed(.transferIncomplete, code: "transfer_incomplete"))
                == MoveFailure(.transferIncomplete, code: "transfer_incomplete")
        )
        #expect(FinishSetupGate.failure(of: .stateRollback) == MoveFailure(.other))
    }

    /// (§6.7.1) The unlock's own `no_user_guid` refusal keeps its code, so the screens tell it apart; the kind alone or the
    /// code alone is not it.
    @Test func aRefusalWithoutAUserGuidKeepsItsCode() {
        let f = FinishSetupGate.failure(of: .failed(.notSupported, code: UnlockAttempt.codeNoUserGuid))
        #expect(f == MoveFailure(.notSupported, code: UnlockAttempt.codeNoUserGuid) && f?.noUserGuid == true)
        #expect(FinishSetupGate.failure(of: .failed(.notSupported, code: "other"))?.noUserGuid == false)
        #expect(FinishSetupGate.failure(of: .failed(.other, code: UnlockAttempt.codeNoUserGuid))?.noUserGuid == false)
    }
}
