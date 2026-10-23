#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDConnections
@testable import VettIDConnectionsUI
import VettIDData
import VettIDUI

// Expected texts stay on one line each.
// swiftlint:disable line_length

/// The connection page's two sharing cards, "You share with <First>" (outgoing) and "<First> shares with you" (incoming): their
/// texts (vettid-android's, word for word), each state rendered, the actions the app must offer and the rule delete
/// confirmation. Mirrors vettid-android `ConnectionSharingCardsTest`.
@MainActor
@Suite struct ConnectionSharingCardsTests {
    private static let utc = TimeZone(identifier: "UTC") ?? .gmt
    private static let end = Date(timeIntervalSince1970: 1_798_718_400)
    /// The name as sentences hold it: bidi-isolated (§10.8).
    private let ada = AccountNames.isolate("Ada")

    private let rule1 = ShareRule(ruleID: "r1", connectionID: "c1", tags: ["medical"], mode: .auto, uses: 5, included: ["i1"])
    private let address = ShareRule(ruleID: "r1", connectionID: "c1", tags: ["address"], mode: .auto, included: ["i1"])
    private let license = ShareRule(
        ruleID: "r2", connectionID: "c1", tags: ["drivers-license"], uses: 5, expiresAt: ConnectionSharingCardsTests.end,
        included: ["i2"], pending: ["i3"]
    )
    private let travel = ShareRule(
        ruleID: "r3", connectionID: "c1", tags: ["drivers-license", "travel"], match: .all, mode: .auto, uses: 1, included: ["i2", "i4"]
    )
    private let outGrant = GrantView(grantID: "g1", connectionID: "c1", direction: .given, itemRef: "i1", name: "Allergies", category: "medical", ruleID: "r1")
    private let inGrant = GrantView(grantID: "g3", connectionID: "c1", direction: .received, itemRef: "x1", name: "Home address", category: "contact")

    @Test func theTextsAreAndroids() {
        #expect(ConnectStrings.shareOutTitle(ada) == "You share with \(ada)" && ConnectStrings.shareOutTitleUnnamed == "You share with this connection")
        #expect(ConnectStrings.shareInTitle(ada) == "\(ada) shares with you" && ConnectStrings.shareInTitleUnnamed == "This connection shares with you")
        #expect(ConnectStrings.shareOutEmpty(ada) == "You’re not sharing anything with \(ada) yet.")
        #expect(ConnectStrings.shareInEmpty(ada) == "\(ada) isn’t sharing anything with you yet.")
        #expect(ConnectStrings.shareInEmptyUnnamed == "This connection isn’t sharing anything with you yet.")
        #expect(ConnectStrings.shareOutCount(0) == "0 items shared" && ConnectStrings.shareOutCount(1) == "1 item shared" && ConnectStrings.shareOutCount(2) == "2 items shared")
        #expect(ConnectStrings.shareInCount(1) == "1 item shared with you" && ConnectStrings.shareInCount(3) == "3 items shared with you")
        #expect(ConnectStrings.shareInAsked(1) == "You asked for 1 thing; waiting for an answer." && ConnectStrings.shareInAsked(2) == "You asked for 2 things; waiting for an answer.")
        #expect(ConnectStrings.shareOutAction == "Add a rule" && ConnectStrings.shareOutManage == "Manage what you share")
        #expect(ConnectStrings.shareInAction == "Ask for something" && ConnectStrings.shareInOpen == "See what is shared with you")
        #expect(ConnectStrings.shareRuleDeleteTitle == "Delete this sharing rule?" && ConnectStrings.shareRuleDelete == "Delete this rule")
        #expect(ConnectStrings.shareRuleDeleteBody(ada) == "\(ada) can no longer fetch the items this rule shared. Items another rule shares stay shared, and nothing becomes shared because this rule is gone.")
        #expect(ConnectStrings.shareRuleDeleteUnnamed.hasPrefix("This connection can no longer fetch the items this rule shared."))
        #expect(ConnectStrings.shareTheirs(ada) == "\(ada)’s" && ConnectStrings.theirsUnnamed == "Theirs")
    }

    @Test func aRuleRowSaysItsSettings() {
        let until = ConnectTimes.dayLabel(Self.end, zone: Self.utc)
        #expect(SharingCardTexts.mode(rule1.mode) == "Shared automatically" && SharingCardTexts.mode(license.mode) == "Asks you each time")
        #expect(SharingCardTexts.limits(rule1, zone: Self.utc) == "up to 5 fetches of each item · no end date")
        #expect(SharingCardTexts.limits(address, zone: Self.utc) == "no fetch limit · no end date")
        #expect(SharingCardTexts.limits(license, zone: Self.utc) == "up to 5 fetches of each item · until \(until)")
        #expect(SharingCardTexts.limits(travel, zone: Self.utc) == "up to 1 fetch of each item · no end date")
        #expect(SharingCardTexts.match(travel.match) == "Items with all of these tags" && SharingCardTexts.match(.any) == "Items with any of these tags")
        #expect(SharingCardTexts.counts(address) == "1 item shared now" && SharingCardTexts.counts(license) == "1 item shared now · 1 waiting for you")
        #expect(SharingCardTexts.counts(travel) == "2 items shared now")
        // 0.23.0: per hour and per day of all the rule's items together.
        let limited = ShareRule(ruleID: "r7", connectionID: "c1", tags: ["medical"], perHour: 5, perDay: 20)
        #expect(SharingCardTexts.limits(limited, zone: Self.utc) == "up to 5 an hour · up to 20 a day · no end date")
    }

    /// The same tag and item in r2 and r3: the `ask` rule wins (§10.12, 0.23.0), rules named by their tags; none for r1.
    @Test func overlapsNameTheOtherRulesByTheirTags() {
        let rules = [address, license, travel]
        let overlaps = DetailSharing(rules: rules).overlaps
        let names = RuleNames.of(rules)
        #expect(SharingCardTexts.overlap(license, overlaps["r2"] ?? [], names: names) == "Overlaps your “drivers-license + travel” rule")
        #expect(SharingCardTexts.overlap(travel, overlaps["r3"] ?? [], names: names) == "Asks you first for the items your “drivers-license” rule also covers")
        #expect(SharingCardTexts.overlap(address, overlaps["r1"] ?? [], names: names) == nil)
        // Two rules that read the same are told apart (by mode, else by end).
        let twinAsk = ShareRule(ruleID: "r8", connectionID: "c1", tags: ["medical"], mode: .ask)
        let twins = RuleNames.of([rule1, twinAsk])
        #expect(SharingCardTexts.named(rule1, names: twins) == "your “medical” rule (shares automatically)")
        #expect(SharingCardTexts.named(twinAsk, names: twins) == "your “medical” rule (asks first)")
        let ending = ShareRule(ruleID: "r9", connectionID: "c1", tags: ["a"], expiresAt: Self.end)
        let open = ShareRule(ruleID: "r10", connectionID: "c1", tags: ["a"])
        let ends = RuleNames.of([ending, open])
        #expect(SharingCardTexts.named(ending, names: ends, zone: Self.utc) == "your “a” rule (until \(ConnectTimes.dayLabel(Self.end, zone: Self.utc)))")
        #expect(SharingCardTexts.named(open, names: ends) == "your “a” rule (no end date)")
    }

    @Test func theGrantLines() {
        #expect(SharingCardTexts.givenLine(outGrant) == "From a rule")
        var oneOff = outGrant
        oneOff.ruleID = nil
        oneOff.uses = 3
        oneOff.used = 1
        #expect(SharingCardTexts.givenLine(oneOff) == "Shared once · 2 uses left")
        var gone = outGrant
        gone.name = " "
        #expect(SharingCardTexts.givenName(gone) == "Deleted item" && SharingCardTexts.givenName(outGrant) == "Allergies")
        #expect(SharingCardTexts.receivedLine(inGrant, name: ada) == "\(ada)’s")
        #expect(SharingCardTexts.receivedLine(inGrant, name: nil) == "Theirs")
        var limited = inGrant
        limited.perHour = 1
        limited.perDay = 3
        #expect(SharingCardTexts.receivedLine(limited, name: ada) == "\(ada)’s · up to 1 time an hour · up to 3 times a day")
        var labelled = inGrant
        labelled.name = ""
        labelled.label = "Their words"
        #expect(SharingCardTexts.receivedName(labelled) == "Their words")
        labelled.label = nil
        #expect(SharingCardTexts.receivedName(labelled) == "Deleted item")
    }

    @Test func theCardsRenderInEveryState() {
        let asked = GrantAsk(requestID: "q", connectionID: "c1", entries: [], state: "pending")
        let full = (1...64).map { ShareRule(ruleID: "f\($0)", connectionID: "c1", tags: ["t\($0)"]) }
        let states = [
            DetailSharing(),
            DetailSharing(loaded: true),
            DetailSharing(rules: [rule1], given: [outGrant], received: [inGrant], asked: [asked], loaded: true),
            DetailSharing(rules: [address, license, travel], loaded: true),
            DetailSharing(rules: full, loaded: true),
            DetailSharing(loaded: true, failed: true),
        ]
        for name in ["Ada", nil] {
            for s in states {
                let out = OutgoingSharingCard(sharing: s, first: name, onShare: {}, onOpenRule: { _ in }, onManage: {}, onDeleteRule: { _ in })
                let incoming = IncomingSharingCard(sharing: s, first: name, onAsk: {}, onOpen: {})
                #expect(height(out) > 0 && height(incoming) > 0, "\(s)")
            }
        }
    }

    @Test func theDetailShowsTheCardsOnlyWithEverySharingHook() {
        var actions = DetailActions()
        #expect(!actions.hasSharing)
        actions.onSharing = {}
        actions.onSharedWithYou = {}
        actions.onShareItems = {}
        actions.onOpenRule = { _ in }
        #expect(!actions.hasSharing)
        actions.onAskForSomething = {}
        #expect(actions.hasSharing)
        var state = ConnectionDetailState(connectionID: "c1")
        state.loading = false
        state.connection = ConnectionsScreensTests.connection("c1")
        state.sharing = DetailSharing(rules: [rule1], given: [outGrant], received: [inGrant], loaded: true)
        state.deleteRule = rule1
        #expect(height(ConnectionDetailScreen(state: state, actions: actions)) > 0)
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}
// swiftlint:enable line_length
#endif
