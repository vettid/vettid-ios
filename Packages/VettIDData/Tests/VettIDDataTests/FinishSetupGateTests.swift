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
        #expect(FinishSetupGate.failure(of: .badPin(retryAfterSeconds: 0)) == .badPin)
        #expect(FinishSetupGate.failure(of: .backoff(retryAfterSeconds: 30)) == .backoff)
        #expect(FinishSetupGate.failure(of: .failed(.transferIncomplete, code: "transfer_incomplete")) == .transferIncomplete)
        #expect(FinishSetupGate.failure(of: .stateRollback) == .other)
    }
}
