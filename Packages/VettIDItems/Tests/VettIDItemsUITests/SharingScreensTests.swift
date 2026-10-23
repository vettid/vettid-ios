#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDDataTesting
@testable import VettIDItems
@testable import VettIDItemsUI
import VettIDUI

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The sharing screens: what a connection can see, the rule editor and what a connection shares, every state rendered, and
/// what the routes wire to the view models. Mirrors vettid-android's `SharingScreensTest` (its text cases are
/// `SharingTextsTests`).
@MainActor
@Suite struct SharingScreensTests {
    let address = ShareRule(ruleID: "r1", version: 1, connectionID: "c1", tags: ["address"], mode: .auto, included: ["i1"])
    let license = ShareRule(ruleID: "r2", version: 1, connectionID: "c1", tags: ["drivers-license"], uses: 5, expiresAt: Date(timeIntervalSince1970: 1_798_718_400), included: ["i2"], pending: ["i3"])
    let travel = ShareRule(ruleID: "r3", version: 1, connectionID: "c1", tags: ["drivers-license", "travel"], match: .all, mode: .auto, uses: 1, included: ["i2"])
    let utc = TimeZone(identifier: "UTC")!

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.dark)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private func connection(_ rules: [ShareRule] = [], given: [GrantView] = []) -> ConnectionSharingState {
        var s = ConnectionSharingState(connectionID: "c1", connectionName: "Dana Lee")
        s.rules = rules
        s.given = given
        s.loading = false
        return s
    }

    // MARK: - What a connection can see

    @Test func everyStateOfTheConnectionsSharingRenders() {
        let passport = ItemSummary(itemID: "i1", version: 1, name: "Passport", category: "identity_document", sensitivity: .critical, tags: [], labels: [], updatedAt: nil)
        let grants = [
            GrantView(grantID: "g1", connectionID: "c1", direction: .given, itemRef: "i1", name: "Passport", category: "identity_document", ruleID: "r1", uses: 3, used: 1),
            GrantView(grantID: "g2", connectionID: "c1", direction: .given, itemRef: "i2", name: "", category: "other", expiresAt: Date(timeIntervalSince1970: 1_798_718_400)),
        ]
        var loading = ConnectionSharingState(connectionID: "c1")
        loading.loading = true
        var full = connection([address, license, travel], given: grants)
        full.items = ["i1": passport]
        var pending = full
        pending.rules = [license]
        var failed = connection()
        failed.error = .limit
        failed.limit = VaultLimit("grants_given", max: 512)
        var revoking = full
        revoking.confirmRevoke = grants[0]
        var revokingOne = full
        revokingOne.confirmRevoke = grants[1]
        let atLimit = connection((1...64).map { ShareRule(ruleID: "f\($0)", version: 1, connectionID: "c1", tags: ["t\($0)"]) })
        for s in [loading, connection(), full, pending, failed, revoking, revokingOne, atLimit] {
            #expect(height(ConnectionSharingScreen(state: s, actions: ConnectionSharingActions())) > 0)
        }
        #expect(full.usable == ["i1"] && full.pendingCount == 1 && atLimit.atRuleLimit && !full.atRuleLimit)
    }

    @Test func sixtyFourRulesNameTheLimitAndAddNoRule() {
        #expect(VaultLimit(RuleLimitNotice.limitName, max: 64).message == "This connection has the most share rules it can have (64).")
        #expect(height(RuleLimitNotice()) > 0)
    }

    @Test func theConnectionsScreenReadsWhatTheViewModelLoaded() async {
        let sharing = FakeSharing()
        sharing.rulesStored = [license]
        sharing.given = [GrantView(grantID: "g1", connectionID: "c1", direction: .given, itemRef: "i1", name: "Passport", category: "identity_document")]
        let vm = ConnectionSharingViewModel(connectionID: "c1", sharing: sharing, items: FakeItems(), connections: FakeConnections())
        await vm.settle()
        var opened: [String?] = []
        var host = ItemsHost()
        host.onOpenRule = { _, rule in opened.append(rule) }
        #expect(vm.state.rules.map(\.ruleID) == ["r2"] && vm.state.given.count == 1)
        // The screen's actions, as the route builds them.
        vm.askRevoke(vm.state.given[0])
        #expect(vm.state.confirmRevoke?.grantID == "g1")
        vm.askRevoke(nil)
        #expect(vm.state.confirmRevoke == nil)
        host.onOpenRule("c1", nil)
        host.onOpenRule("c1", "r2")
        #expect(opened == [nil, "r2"])
    }

    // MARK: - The rule editor

    private func edit(_ draft: RuleDraft = RuleDraft(connectionID: "c1"), tags: [String] = ["address", "medical", "travel"]) -> RuleEditState {
        var s = RuleEditState(draft: draft, connectionName: "Dana Lee")
        s.tags = tags
        return s
    }

    @Test func everyStateOfTheRuleEditorRenders() {
        let chosen = edit(RuleDraft(connectionID: "c1", tags: ["medical"]))
        var states: [RuleEditState] = [edit(), chosen]
        var loading = edit()
        loading.loading = true
        var none = edit(tags: [])
        none.loading = false
        var dirty = chosen
        dirty.dirty = true
        dirty.confirmDiscard = true
        var deleting = edit(RuleDraft.of(license))
        deleting.rules = [address, license, travel]
        deleting.confirmDelete = true
        var custom = edit(RuleDraft(connectionID: "c1", tags: ["address"], expiresAt: Date(timeIntervalSince1970: 1_798_714_740)))
        custom.expiry = .custom
        custom.endInvalid = true
        var kept = edit(RuleDraft.of(license))
        kept.expiry = .keep
        kept.usesText = "5"
        kept.rules = [address, license, travel]
        kept.preview = RulePreview(matches: [
            RuleMatch(itemID: "i2", name: "Driver’s license", category: "identity_document", sensitivity: .data, state: "included"),
            RuleMatch(itemID: "i4", name: "Library card", category: "membership", sensitivity: .data),
            RuleMatch(itemID: "i9", name: "Key", category: "crypto_wallet", sensitivity: .critical, outcome: RuleMatch.outcomeAsk, askRuleID: "r3"),
        ], total: 5)
        var bad = chosen
        bad.usesText = "0"
        bad.perHourText = "5000"
        bad.perDayText = "0"
        var limited = edit()
        limited.rules = (1...64).map { ShareRule(ruleID: "f\($0)", version: 1, connectionID: "c1", tags: ["t\($0)"]) }
        limited.error = .limit
        limited.limit = VaultLimit("share_rules", max: 512)
        var previewing = chosen
        previewing.previewing = true
        var readOnly = edit(RuleDraft.of(travel), tags: ["drivers-license", "travel"])
        readOnly.readOnly = true
        readOnly.rules = [travel]
        states += [loading, none, dirty, deleting, custom, kept, bad, limited, previewing, readOnly]
        for s in states { #expect(height(RuleEditScreen(state: s, actions: RuleEditActions())) > 0) }
        #expect(limited.atRuleLimit && !limited.canSave && !readOnly.canSave && !edit().canSave && chosen.canSave && !bad.canSave)
    }

    @Test func theTagIsChosenOnceAndATakenTagOpensItsRule() {
        var s = edit(tags: ["address", "medical", "travel"])
        s.rules = [address]
        // "address" has its rule: not a choice, it opens that rule.
        #expect(s.freeTags == ["medical", "travel"] && s.taken == ["address": "r1"])
        s.draft.tags = ["medical"]
        #expect(s.tag == "medical" && s.canSave)
        var opened: [String] = []
        var a = RuleEditActions()
        a.onOpenRule = { opened.append($0) }
        a.onOpenRule("r1")
        #expect(opened == ["r1"] && height(RuleTagsSection(state: s, name: "Dana Lee", actions: a)) > 0)
        #expect(height(TagChoice(tag: "medical", selected: true) {}) > 0 && height(TagChoice(tag: "medical", selected: false) {}) > 0)
    }

    @Test func theEditorOffersEveryEndAndKeepsAnExistingOne() {
        #expect(RuleExpiry.allCases.map(\.identifier) == ["never", "day", "week", "month", "three_months", "year", "custom", "keep"])
        var s = edit(RuleDraft(connectionID: "c1", tags: ["address"], expiresAt: Date(timeIntervalSince1970: 1_798_714_740)))
        s.expiry = .custom
        #expect(height(RuleEndsSection(state: s, onExpiry: { _ in })) > 0)
        s.expiry = .keep
        #expect(height(RuleEndsSection(state: s, onExpiry: { _ in })) > 0)
        #expect(height(NumberField(text: "5", onChange: { _ in }, caption: "c", valid: false, note: "n", bad: "b", id: "x")) > 0)
    }

    @Test func theCustomEndGoesFromTheDateToTheTimeOfTheEndOfTheDay() {
        let now = Date(timeIntervalSince1970: 1_791_384_000)
        var date = RuleEditActions()
        var picked: [RuleEnds.Day] = []
        date.onEndDate = { picked.append($0) }
        // The time starts at the end of the picked day, or at the end the rule has.
        #expect(EndPickerSheet.hourAndMinute(of: nil, zone: utc) == (23, 59))
        #expect(EndPickerSheet.hourAndMinute(of: Date(timeIntervalSince1970: 1_798_718_400), zone: utc) == (12, 0))
        #expect(EndPickerSheet.hourAndMinute(of: Date(timeIntervalSince1970: 1_798_718_400), zone: TimeZone(identifier: "America/New_York")!) == (7, 0))
        let day = RuleEnds.Day(year: 2026, month: 12, day: 31)
        for picker in [EndPicker.date, .time(day)] {
            #expect(height(EndPickerSheet(picker: picker, current: nil, actions: date, zone: utc, now: now)) > 0)
            #expect(height(EndPickerSheet(picker: picker, current: Date(timeIntervalSince1970: 1_798_718_400), actions: date, zone: utc, now: now)) > 0)
        }
    }

    @Test func theRuleRouteWiresTheViewModelAndLeavesWhenDone() async {
        let sharing = FakeSharing()
        sharing.registry = TagRegistry(version: 1, tags: [TagView(tag: "medical", items: 1)])
        let items = FakeItems()
        let vm = RuleEditViewModel(connectionID: "c1", ruleID: nil, sharing: sharing, items: items, connections: FakeConnections(), debounce: .milliseconds(5))
        await vm.settle()
        vm.selectTag("medical")
        vm.setMode(.auto)
        vm.setUses("3")
        await vm.settle()
        #expect(vm.state.canSave && vm.state.dirty)
        vm.save()
        await vm.settle()
        #expect(vm.state.done && sharing.saved.first?.tags == ["medical"] && sharing.saved.first?.mode == .auto && sharing.saved.first?.uses == 3)
        // The route makes its model when it appears, and only then.
        for _ in 0..<3 { _ = RuleEditRoute(connectionID: "c1", ruleID: "r1", sharing: sharing, items: items, connections: FakeConnections(), host: ItemsHost()) }
        #expect(sharing.saved.count == 1)
    }

    // MARK: - What a connection shares

    private func shared(received: [GrantView] = [], _ edit: (inout SharedWithYouState) -> Void = { _ in }) -> SharedWithYouState {
        var s = SharedWithYouState(connectionID: "c1", connectionName: "Dana Lee")
        s.received = received
        s.loading = false
        edit(&s)
        return s
    }

    @Test func everyStateOfSharedWithYouRenders() {
        let g5 = GrantView(grantID: "g5", connectionID: "c1", direction: .received, itemRef: "x1", name: "Insurance card", category: "insurance", labels: [GrantFieldLabel(fieldID: "f1", label: "Policy", kind: "text")])
        let g6 = GrantView(grantID: "g6", connectionID: "c1", direction: .received, itemRef: "x2", name: "Card", category: "insurance", uses: 3, used: 1, expiresAt: Date(timeIntervalSince1970: 1_798_718_400), perHour: 5, perDay: 1)
        let g7 = GrantView(grantID: "g7", connectionID: "c1", direction: .received, itemRef: "x3", name: "Old", category: "other", state: "revoked")
        let content = SharedContent(itemID: "x1", name: "Insurance card", category: "insurance", fields: [
            ItemFieldView(fieldID: "f1", label: "Policy", kind: FieldKinds.text, value: .text("P-42")),
            ItemFieldView(fieldID: "f2", label: "Phone", kind: FieldKinds.phone, value: .text("+1 650-253-0000")),
            ItemFieldView(fieldID: "f3", label: "Address", kind: FieldKinds.address, value: .address(AddressValue(city: "London", country: "GB"))),
            ItemFieldView(fieldID: "f4", label: "Empty", kind: FieldKinds.text, value: .text("")),
        ], notes: "ring first", usesLeft: 2)
        var loading = SharedWithYouState(connectionID: "c1")
        loading.loading = true
        var states = [loading, shared(), shared(received: [g5, g6, g7])]
        states.append(shared(received: [g5, g6, g7]) { $0.opened = ["g5": content]; $0.refused = ["g6": "exhausted"] })
        states.append(shared(received: [g5, g6]) { $0.refused = ["g6": "rate_limited"]; $0.retryAt = ["g6": Date().addingTimeInterval(12 * 60)]; $0.fetching = "g5" })
        states.append(shared(received: [g5]) { $0.error = .network; $0.confirmGiveUp = g5 })
        states.append(shared { $0.requested = [GrantAsk(requestID: "q1", connectionID: "c1", entries: [GrantAskEntry(kind: "category", ref: "insurance", label: "My card"), GrantAskEntry(kind: "item", ref: "x")], state: "pending"), GrantAsk(requestID: "q2", connectionID: "c1", entries: [], state: "denied")]; $0.asked = true })
        states.append(shared { $0.ask = GrantAskForm(category: "insurance", label: "Card", reason: "Booking") })
        states.append(shared { $0.ask = GrantAskForm(busy: true) })
        for s in states { #expect(height(SharedWithYouScreen(state: s, actions: SharedWithYouActions())) > 0) }
        #expect(height(AskSheet(form: GrantAskForm(), name: "Dana Lee", actions: SharedWithYouActions())) > 0)
        #expect(height(ReceivedCard(grant: g5, state: states[3], name: "Dana Lee", actions: SharedWithYouActions())) > 0)
        // A phone number is shown formatted for the region, an address in lines, an empty value as such.
        #expect(SharedFields.text(content.fields[0]) == "P-42" && SharedFields.text(content.fields[2]).contains("London"))
        #expect(SharedFields.text(content.fields[1]) == PhoneInput.display("+1 650-253-0000"))
        #expect(height(SharedFields(content: content)) > 0)
    }

    @Test func theFetchedValuesAreOnTheSecureLayer() throws {
        try #require(SecureLayer.isAvailable, "no secure layer on this iOS: the cover and capture hiding protect the values")
        let g = GrantView(grantID: "g5", connectionID: "c1", direction: .received, itemRef: "x1", name: "Card", category: "insurance")
        let content = SharedContent(itemID: "x1", name: "Card", category: "insurance", fields: [ItemFieldView(fieldID: "f1", label: "Policy", kind: FieldKinds.text, value: .text("P-42"))], notes: nil, usesLeft: nil)
        let screen = SharedWithYouScreen(state: shared(received: [g]) { $0.opened = ["g5": content] }, actions: SharedWithYouActions())
        let host = UIHostingController(rootView: screen.vettIDTheme(.dark))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        func all(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(all) }
        #expect(all(host.view).contains { String(describing: type(of: $0)).contains("Canvas") })
    }

    @Test func whatWasFetchedGoesInTheBackgroundAndWhenTheScreenGoes() async {
        let sharing = FakeSharing()
        sharing.received = [GrantView(grantID: "g5", connectionID: "c1", direction: .received, itemRef: "x1", name: "Card", category: "insurance")]
        sharing.contents = ["g5": SharedContent(itemID: "x1", name: "Card", category: "insurance", fields: [], notes: nil, usesLeft: nil)]
        let vm = SharedWithYouViewModel(connectionID: "c1", sharing: sharing, items: FakeItems(), connections: FakeConnections())
        await vm.settle()
        vm.fetch("g5")
        await vm.settle()
        #expect(vm.state.opened["g5"] != nil)
        SharedWithYouRoute.phaseChanged(.inactive, vm)
        #expect(vm.state.opened["g5"] != nil, "only inactive, as under a system prompt")
        SharedWithYouRoute.phaseChanged(.background, vm)
        #expect(vm.state.opened.isEmpty)
        vm.fetch("g5")
        await vm.settle()
        SharedWithYouRoute.left(vm)
        #expect(vm.state.opened.isEmpty)
    }

    @Test func theAskFormIsCutAtBytesAndSent() async {
        let sharing = FakeSharing()
        let vm = SharedWithYouViewModel(connectionID: "c1", ask: true, sharing: sharing, items: FakeItems(), connections: FakeConnections())
        await vm.settle()
        #expect(vm.state.ask != nil)
        var host = ItemsHost()
        var left = 0
        host.onBack = { left += 1 }
        let a = SharedWithYouRoute.actions(vm, host: host)
        // What the sheet's fields hand over, cut as they cut it.
        var form = GrantAskForm(category: "insurance")
        form.label = Utf8Cap.label(String(repeating: "é", count: 100))
        form.reason = Utf8Cap.reason(String(repeating: "日", count: 100))
        a.onAsk(form)
        #expect(vm.state.ask?.label.utf8.count == 128 && vm.state.ask?.reason.utf8.count == 255)
        a.onSendAsk()
        await vm.settle()
        #expect(sharing.requests.count == 1 && sharing.requests[0].category == "insurance" && vm.state.asked && vm.state.ask == nil)
        a.onOpenAsk(true)
        #expect(vm.state.ask == GrantAskForm())
        a.onBack()
        #expect(left == 1)
        // The routes make their models when they appear, and only then.
        for _ in 0..<3 { _ = SharedWithYouRoute("c1", ask: true, sharing: sharing, items: FakeItems(), connections: FakeConnections(), host: ItemsHost()) }
        #expect(sharing.requests.count == 1)
    }

    @Test func makingTheRoutesSendsNothing() {
        let sharing = FakeSharing()
        let items = FakeItems()
        let connections = FakeConnections()
        for _ in 0..<3 {
            _ = ConnectionSharingRoute("c1", sharing: sharing, items: items, connections: connections, host: ItemsHost())
            _ = RuleEditRoute(connectionID: "c1", ruleID: nil, sharing: sharing, items: items, connections: connections, host: ItemsHost())
            _ = SharedWithYouRoute("c1", ask: false, sharing: sharing, items: items, connections: connections, host: ItemsHost())
        }
        #expect(sharing.calls.isEmpty && items.calls.isEmpty)
    }
}

// swiftlint:enable line_length
#endif
