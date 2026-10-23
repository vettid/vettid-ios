import Foundation
import Testing
@testable import VettIDApprovals
@testable import VettIDData

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// Why a share question's item is asked and what an answer does (VAULT-MESSAGING 0.23.0 §10.12 Overlapping rules). Mirrors
/// vettid-android `ApprovalsViewModelsTest`'s share explanations.
@Suite struct ShareExplanationsTests {
    private func decision(_ items: [ShareItem], rule: String = "r2") -> ShareDecision {
        ShareDecision(ruleID: rule, subjectConnectionID: "c1", subjectAgentID: nil, items: items, reason: nil, receivedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func aShareQuestionExplainsTheRuleThatAsksAndAnItemAlreadyShared() {
        let d = decision([
            ShareItem(itemID: "i1", name: "A", category: "medical", sensitivity: "data", askRuleID: "r1", alsoIn: ["r1", "r3"]),
            ShareItem(itemID: "i2", name: "B", category: "x", sensitivity: "data", shared: true),
            ShareItem(itemID: "i3", name: "C", category: "x", sensitivity: "data"),
        ])
        #expect(ShareExplanations.of(d.items[0], d) == [.asksFirst(ruleID: "r1"), .alsoCovered(ruleID: "r3")])
        #expect(ShareExplanations.of(d.items[1], d) == [.alreadyShared])
        #expect(ShareExplanations.of(d.items[2], d).isEmpty)
    }

    /// The question's own rule is never "also covering" it, nor named as the one that asks.
    @Test func theQuestionsOwnRuleIsNeverNamed() {
        let d = decision([ShareItem(itemID: "i1", name: "A", category: "x", sensitivity: "data", askRuleID: "r2", shared: true, alsoIn: ["r2", "r4"])])
        #expect(ShareExplanations.of(d.items[0], d) == [.alsoCovered(ruleID: "r4"), .alreadyShared])
    }
}

// swiftlint:enable line_length
