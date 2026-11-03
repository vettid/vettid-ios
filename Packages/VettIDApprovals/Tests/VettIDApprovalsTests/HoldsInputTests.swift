import Testing
@testable import VettIDApprovals

/// An approval open for a decision holds a due daily check while it is open, typed or not (VAULT-MESSAGING §3.6.5: the
/// check must not interrupt "an approval"); a decided, gone or withdrawn one does not.
@Suite struct ApprovalHoldsInputTests {
    @Test func anOpenUndecidedApprovalHolds() {
        var s = ApprovalDetailState(key: "a1")
        #expect(!s.holdsInput, "not loaded")
        s.approval = Samples.auth()
        #expect(s.holdsInput)
        for end in [\ApprovalDetailState.done, \.gone, \.withdrawn] {
            var ended = s
            ended[keyPath: end] = true
            #expect(!ended.holdsInput)
        }
    }
}
