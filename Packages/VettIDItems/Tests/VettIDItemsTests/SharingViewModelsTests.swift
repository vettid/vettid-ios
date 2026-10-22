import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDItems

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The sharing view models against ``FakeSharing``: the connection's rules and grants, the rule editor and what a connection
/// shares with the member (VAULT-MESSAGING §10.12). Mirrors the sharing tests of vettid-android's `SharingViewModelsTest`
/// (its tag tests are `TagsViewModelTests`).
@MainActor
@Suite struct SharingViewModelsTests {
    let sharing = FakeSharing()
    let social = FakeConnections()
    let items = FakeItems()
    let utc = TimeZone(identifier: "UTC")!
    let newYork = TimeZone(identifier: "America/New_York")!
    let now = date("2026-10-09T10:00:00Z")

    init() {
        sharing.registry = TagRegistry(version: 3, tags: [TagView(tag: "@profile", items: 1), TagView(tag: "medical", items: 2, rules: ["r1"]), TagView(tag: "travel", items: 1)])
        var c = ConnectionInfo(id: "c1", name: "", state: .active)
        c.firstName = "Dana"
        c.lastName = "Lee"
        social.connections = [c]
        items.add(FakeItems.item("i1", "Allergies", tags: ["medical"]))
        items.add(FakeItems.item("i9", "Signing key", sensitivity: .critical, tags: ["medical"]))
    }

    func ruleVM(_ ruleID: String? = nil) async -> RuleEditViewModel {
        let vm = RuleEditViewModel(connectionID: "c1", ruleID: ruleID, sharing: sharing, items: items, connections: social, debounce: .milliseconds(20))
        await vm.settle()
        return vm
    }

    func connectionVM() async -> ConnectionSharingViewModel {
        let vm = ConnectionSharingViewModel(connectionID: "c1", sharing: sharing, items: items, connections: social)
        await vm.settle()
        return vm
    }

    func sharedVM(ask: Bool = false, now: @escaping @Sendable () -> Date = { Date() }) async -> SharedWithYouViewModel {
        let vm = SharedWithYouViewModel(connectionID: "c1", ask: ask, sharing: sharing, items: items, connections: social, now: now)
        await vm.settle()
        return vm
    }

    // MARK: - The rule editor

    @Test func aNewRuleAsksForEachNewItemByDefaultAndPreviews() async {
        sharing.preview = RulePreview(matches: [RuleMatch(itemID: "i1", name: "Allergies", category: "medical", sensitivity: .data)], total: 1)
        let vm = await ruleVM()
        let s = vm.state
        #expect(s.draft.mode == .ask && s.draft.includeExisting)
        #expect(s.tags == ["medical", "travel"], "no reserved tag")
        #expect(s.connectionName == "Dana Lee")
        #expect(!s.canSave)
        vm.selectTag("medical")
        await vm.settle()
        #expect(vm.state.preview?.total == 1)
        vm.setUses("0")
        #expect(!vm.state.canSave)
        vm.setUses("12")
        vm.setMode(.auto)
        vm.setExpiry(.month, now: date("2026-10-09T10:00:00Z"), zone: utc)
        vm.save()
        await vm.settle()
        let d = sharing.saved.first
        #expect(d?.tags == ["medical"] && d?.uses == 12 && d?.mode == .auto)
        #expect(d?.expiresAt == date("2026-11-09T10:00:00Z"))
        #expect(vm.state.done)
    }

    @Test func anExistingRuleIsEditedAndDeleted() async {
        sharing.rulesStored.append(ShareRule(ruleID: "r1", version: 2, connectionID: "c1", tags: ["medical"], match: .any, mode: .auto, uses: 3))
        let vm = await ruleVM("r1")
        #expect(vm.state.draft.mode == .auto && vm.state.usesText == "3" && vm.state.draft.version == 2)
        vm.askDelete(true)
        vm.delete()
        await vm.settle()
        #expect(sharing.calls.contains("deleteRule") && vm.state.done)
    }

    @Test func eachEndPresetCountsFromNowInTheMembersZone() async {
        let vm = await ruleVM()
        vm.selectTag("medical")
        let expected: [(RuleExpiry, String?)] = [
            (.never, nil), (.day, "2026-10-10T10:00:00Z"), (.week, "2026-10-16T10:00:00Z"),
            // Calendar months in the member's zone: across the clock change of 2026-11-01 the local time (06:00) stays.
            (.month, "2026-11-09T11:00:00Z"), (.threeMonths, "2027-01-09T11:00:00Z"), (.year, "2027-10-09T10:00:00Z"),
        ]
        for (e, at) in expected {
            vm.setExpiry(e, now: now, zone: newYork)
            #expect(vm.state.expiry == e)
            #expect(vm.state.draft.expiresAt == at.map(date), "\(e)")
        }
        #expect(RuleExpiry.presets + [.custom] == RuleExpiry.allCases.filter { $0 != .keep })
    }

    /// "Custom…": the picked day and a local time become one UTC `expires_at` (§10.12).
    @Test func aCustomEndIsAPickedDayAndTimeInLocalTimeSentAsUtc() async {
        let vm = await ruleVM()
        vm.selectTag("medical")
        vm.setExpiry(.day, now: now, zone: utc)
        vm.setExpiry(.custom)
        #expect(vm.state.endPicker == .date)
        #expect(vm.state.expiry == .day, "nothing changes until a time is picked")
        let day = RuleEnds.Day(year: 2026, month: 12, day: 31)
        vm.pickEndDate(day)
        #expect(vm.state.endPicker == .time(day))
        vm.pickEndTime(hour: 23, minute: 59, zone: newYork, now: now)
        let s = vm.state
        #expect(s.endPicker == nil && !s.endInvalid && s.expiry == .custom)
        #expect(s.draft.expiresAt == date("2027-01-01T04:59:00Z"))
        #expect(SharingManager.ruleBody(s.draft, dryRun: false).raw.contains(#""expires_at":"2027-01-01T04:59:00.000Z""#))
        // Cancelling a second pick keeps the end.
        vm.setExpiry(.custom)
        vm.cancelEndPicker()
        #expect(vm.state.endPicker == nil && vm.state.draft.expiresAt == date("2027-01-01T04:59:00Z"))
    }

    @Test func aCustomEndMustBeInTheFutureAndWithinTenYears() async {
        let vm = await ruleVM()
        vm.selectTag("medical")
        let today = RuleEnds.Day(year: 2026, month: 10, day: 9)
        vm.setExpiry(.custom)
        vm.pickEndDate(today)
        vm.pickEndTime(hour: 9, minute: 0, zone: utc, now: now) // an hour ago
        #expect(vm.state.endInvalid && vm.state.draft.expiresAt == nil && vm.state.expiry == .never)
        vm.setExpiry(.custom)
        vm.pickEndDate(today)
        vm.pickEndTime(hour: 10, minute: 30, zone: utc, now: now) // later today
        #expect(!vm.state.endInvalid && vm.state.draft.expiresAt == date("2026-10-09T10:30:00Z"))
        // The calendar offers today up to 3,650 days ahead, in the member's zone.
        #expect(RuleEnds.selectable(.init(year: 2026, month: 10, day: 9), now: now, zone: utc))
        #expect(!RuleEnds.selectable(.init(year: 2026, month: 10, day: 8), now: now, zone: utc))
        #expect(RuleEnds.selectable(.init(year: 2036, month: 10, day: 6), now: now, zone: utc))
        #expect(!RuleEnds.selectable(.init(year: 2036, month: 10, day: 7), now: now, zone: utc))
        #expect(!RuleEnds.allowed(now.addingTimeInterval(3_650 * 86_400), now: now))
        #expect(RuleEnds.allowed(now.addingTimeInterval(3_650 * 86_400 - 60), now: now))
        #expect(RuleEnds.pickerDay(date("2026-10-09T02:00:00Z"), zone: newYork) == .init(year: 2026, month: 10, day: 8))
    }

    @Test func fetchesOfEachItemAreDigitsWithinTheSpecRange() async {
        let vm = await ruleVM()
        vm.selectTag("medical")
        let cases: [(String, Bool)] = [("", true), ("0", false), ("1", true), ("10000", true), ("10001", false), ("5a0", true), ("123456", false)]
        for (typed, ok) in cases {
            vm.setUses(typed)
            #expect(vm.state.usesValid == ok && vm.state.canSave == ok, "\(typed)")
        }
        vm.setUses("5a0")
        #expect(vm.state.usesText == "50" && vm.state.draft.uses == 50)
        vm.setUses("123456")
        #expect(vm.state.usesText == "12345")
        vm.setUses("")
        #expect(vm.state.draft.uses == nil)
    }

    /// Every field of the editor reaches `share.rule.set` (§10.12), and an edit keeps the rule's id and version.
    @Test func everyFieldIsSavedAndAnEditReplacesTheRule() async {
        sharing.registry.tags += [TagView(tag: "address"), TagView(tag: "drivers-license")]
        let vm = await ruleVM()
        vm.selectTag("travel")
        // One tag per rule (owner decision 2026-10-09): choosing another replaces it.
        vm.selectTag("drivers-license")
        vm.setMode(.auto)
        vm.setMode(.ask)
        vm.setUses("3")
        vm.setPerHour("5")
        vm.setPerDay("20")
        vm.setIncludeExisting(false)
        vm.setExpiry(.week, now: now, zone: utc)
        vm.save()
        await vm.settle()
        let first = sharing.saved.first
        #expect(first.map { SharingManager.ruleBody($0, dryRun: false).raw } == #"{"subject":{"connection_id":"c1"},"tags":["drivers-license"],"match":"any","access":"read","mode":"ask","uses":3,"per_hour":5,"per_day":20,"expires_at":"2026-10-16T10:00:00.000Z","include_existing":false}"#)
        // Edit it: the end is kept unless changed; mode and uses change; the id and version go with it.
        let stored = sharing.rulesStored[0]
        let edit = await ruleVM(stored.ruleID)
        #expect(edit.state.expiry == .keep && !edit.state.isNew)
        edit.setMode(.auto)
        edit.setUses("")
        edit.save()
        await edit.settle()
        let d = sharing.saved.last
        #expect(d?.ruleID == stored.ruleID && d?.version == stored.version && d?.mode == .auto && d?.uses == nil)
        #expect(d?.expiresAt == date("2026-10-16T10:00:00Z"))
        #expect(sharing.rulesStored.count == 1)
    }

    @Test func theEditorShowsTheConnectionsOtherRulesCoveringTheSameTagsOrItems() async {
        sharing.rulesStored += [
            ShareRule(ruleID: "r1", connectionID: "c1", tags: ["medical"], mode: .auto, included: ["i1"]),
            ShareRule(ruleID: "r2", connectionID: "c1", tags: ["travel"], included: ["i5"]),
            ShareRule(ruleID: "r3", connectionID: "c1", tags: ["money"], pending: ["i7"]),
            // A rule from before one tag per rule: it names "id" too.
            ShareRule(ruleID: "r4", connectionID: "c1", tags: ["medical", "id"], match: .all),
            ShareRule(ruleID: "r9", connectionID: "c2", tags: ["medical"], included: ["i1"]), // another connection
        ]
        sharing.registry.tags.append(TagView(tag: "id"))
        sharing.preview = RulePreview(matches: [RuleMatch(itemID: "i5", name: "Passport", category: "identity_document", sensitivity: .data)], total: 1)
        let vm = await ruleVM()
        #expect(vm.state.rules.map(\.ruleID) == ["r1", "r2", "r3", "r4"])
        #expect(vm.state.overlaps.isEmpty)
        vm.selectTag("id")
        await vm.settle()
        // r4 names the tag; r2 holds the matched item; r1 and r3 neither.
        #expect(vm.state.overlaps.map(\.ruleID) == ["r2", "r4"])
        // Editing r1 itself: it is not its own overlap (r4 names its tag, r2 holds the item).
        let edit = await ruleVM("r1")
        #expect(edit.state.overlaps.map(\.ruleID) == ["r2", "r4"])
    }

    @Test func theDryRunPreviewFollowsTheDraft() async {
        sharing.preview = RulePreview(matches: [
            RuleMatch(itemID: "i1", name: "Allergies", category: "medical", sensitivity: .data),
            RuleMatch(itemID: "i9", name: "Signing key", category: "crypto_wallet", sensitivity: .critical),
        ], total: 4)
        let vm = await ruleVM()
        #expect(vm.state.preview == nil)
        vm.selectTag("medical")
        vm.setMode(.auto) // debounced: one dry run for both changes
        await vm.settle()
        #expect(sharing.calls.count { $0 == "preview" } == 1)
        #expect(vm.state.preview?.total == 4 && !vm.state.previewing)
        vm.selectTag("medical") // the same tag again changes nothing
        await vm.settle()
        #expect(sharing.calls.count { $0 == "preview" } == 1)
    }

    /// §10.12: 64 rules per connection (`share_rules_subject`); the vault's named limit is shown as it says.
    @Test func aConnectionAtSixtyFourRulesTakesNoNewOneAndTheLimitIsNamed() async {
        for i in 0..<RuleDraft.maxRulesPerSubject { sharing.rulesStored.append(ShareRule(ruleID: "f\(i)", connectionID: "c1", tags: ["medical"])) }
        let vm = await ruleVM()
        vm.selectTag("travel")
        #expect(vm.state.atRuleLimit && !vm.state.canSave)
        vm.save()
        await vm.settle()
        #expect(!sharing.calls.contains("saveRule"))
        // An existing rule can still be changed.
        let edit = await ruleVM("f0")
        #expect(!edit.state.atRuleLimit && edit.state.canSave)
        // The vault's own refusal (512 in all) names its limit.
        sharing.rulesStored.removeAll()
        sharing.fail["saveRule"] = VaultFailure(.limit, code: "limit", limit: VaultLimit("share_rules", max: 512))
        let again = await ruleVM()
        again.selectTag("travel")
        again.save()
        await again.settle()
        #expect(again.state.error == .limit && again.state.limit == VaultLimit("share_rules", max: 512) && !again.state.done)
    }

    @Test func aRuleSharesOneTagAndATagAlreadySharedOpensItsRule() async {
        sharing.rulesStored += [ShareRule(ruleID: "r1", connectionID: "c1", tags: ["medical"]), ShareRule(ruleID: "r9", connectionID: "c2", tags: ["travel"])]
        let vm = await ruleVM()
        let s = vm.state
        #expect(s.taken == ["medical": "r1"] && s.freeTags == ["travel"] && s.tag == nil)
        #expect(!s.canSave, "Save waits for a tag")
        vm.selectTag("medical") // already shared: the screen opens r1 instead
        #expect(vm.state.tag == nil && !vm.state.dirty)
        vm.selectTag("travel")
        #expect(vm.state.draft.tags == ["travel"] && vm.state.draft.match == .any && vm.state.canSave)
        // Its own rule's tag is free to its editor.
        let edit = await ruleVM("r1")
        #expect(edit.state.taken.isEmpty && edit.state.tag == "medical")
    }

    /// A rule naming several tags (made before one tag per rule) is shown read-only: it can be deleted, not changed.
    @Test func aMultiTagRuleIsReadOnlyAndCanBeDeleted() async {
        sharing.rulesStored.append(ShareRule(ruleID: "r2", connectionID: "c1", tags: ["medical", "travel"], match: .all))
        let vm = await ruleVM("r2")
        let s = vm.state
        #expect(s.readOnly && !s.canSave)
        // Its tags do not block a single-tag rule of either: only a rule of exactly one tag does.
        #expect(s.taken.isEmpty)
        vm.setMode(.auto)
        vm.setUses("3")
        vm.setExpiry(.week, now: now, zone: utc)
        #expect(vm.state.draft.mode == .ask && vm.state.draft.uses == nil && vm.state.draft.expiresAt == nil && vm.state.usesText.isEmpty)
        vm.save()
        await vm.settle()
        #expect(!sharing.calls.contains("saveRule"))
        vm.askDelete(true)
        vm.delete()
        await vm.settle()
        #expect(sharing.calls.contains("deleteRule") && vm.state.done)
    }

    /// 0.23.0 §10.12: `per_hour` 1–3,600 and `per_day` 1–86,400 on a connection rule, digits only, optional.
    @Test func perHourAndPerDayAreDigitsWithinTheSpecRanges() async {
        let vm = await ruleVM()
        vm.selectTag("medical")
        for (typed, ok) in [("", true), ("0", false), ("1", true), ("3600", true), ("3601", false), ("6a0", true)] {
            vm.setPerHour(typed)
            #expect(vm.state.perHourValid == ok && vm.state.canSave == ok, "\(typed)")
        }
        vm.setPerHour("")
        for (typed, ok) in [("0", false), ("86400", true), ("86401", false), ("20", true)] {
            vm.setPerDay(typed)
            #expect(vm.state.perDayValid == ok, "\(typed)")
        }
        #expect(vm.state.draft.perDay == 20 && vm.state.draft.perHour == nil)
        vm.setPerHour("123456")
        #expect(vm.state.perHourText == "1234")
        // An existing rule's limits are shown.
        sharing.rulesStored.append(ShareRule(ruleID: "r1", connectionID: "c1", tags: ["travel"], perHour: 5, perDay: 20))
        let edit = await ruleVM("r1")
        #expect(edit.state.perHourText == "5" && edit.state.perDayText == "20")
    }

    /// "Save rule" in the top bar: leaving with changes asks first; nothing changed, nothing to discard.
    @Test func leavingWithChangesAsksToDiscard() async {
        sharing.rulesStored.append(ShareRule(ruleID: "r1", connectionID: "c1", tags: ["medical"]))
        let vm = await ruleVM("r1")
        #expect(!vm.state.dirty)
        vm.setMode(.auto)
        #expect(vm.state.dirty)
        vm.askDiscard(true)
        #expect(vm.state.confirmDiscard)
        vm.askDiscard(false)
        vm.save()
        await vm.settle()
        #expect(!vm.state.dirty && vm.state.done)
    }

    // MARK: - What a connection can see

    @Test func theManageScreenNamesOverlapsAndTheRuleLimit() async {
        sharing.rulesStored += [
            ShareRule(ruleID: "r1", connectionID: "c1", tags: ["medical"], included: ["i1"]),
            ShareRule(ruleID: "r2", connectionID: "c1", tags: ["medical", "travel"], match: .all),
            ShareRule(ruleID: "r3", connectionID: "c1", tags: ["money"]),
        ]
        let vm = await connectionVM()
        let s = vm.state
        #expect(s.overlaps["r1"]?.map(\.ruleID) == ["r2"] && s.overlaps["r3"]?.isEmpty == true && !s.atRuleLimit)
        var full = s
        full.rules = (1...64).map { ShareRule(ruleID: "f\($0)", connectionID: "c1", tags: ["x\($0)"]) }
        #expect(full.atRuleLimit)
    }

    private var given: GrantView { GrantView(grantID: "g1", connectionID: "c1", direction: .given, itemRef: "i1", name: "Allergies", category: "medical", ruleID: "r1", uses: 3, used: 1) }

    @Test func aConnectionSeesItsRulesAndGrants() async {
        sharing.rulesStored.append(ShareRule(ruleID: "r1", connectionID: "c1", tags: ["medical"], included: ["i1", "i9"], pending: ["i5"]))
        var other = given
        other.grantID = "g0"
        other.connectionID = "c2"
        var revoked = given
        revoked.grantID = "g2"
        revoked.state = "revoked"
        sharing.given = [given, other, revoked]
        let vm = await connectionVM()
        let s = vm.state
        #expect(s.active.map(\.grantID) == ["g1"] && s.given.map(\.grantID) == ["g1", "g2"])
        #expect(s.usable == ["i9"] && s.pendingCount == 1 && s.connectionName == "Dana Lee")
        vm.askRevoke(s.active[0])
        vm.revoke()
        await vm.settle()
        #expect(sharing.calls.contains("revoke:g1") && vm.state.active.isEmpty && !vm.state.busy)
    }

    // MARK: - What a connection shares with the member

    @Test func sharedWithYouIsFetchedOnPurposeAndForgottenOnStop() async {
        sharing.received = [
            GrantView(grantID: "g5", connectionID: "c1", direction: .received, itemRef: "x1", name: "Insurance card", category: "insurance"),
            GrantView(grantID: "g6", connectionID: "c1", direction: .received, itemRef: "x2", name: "Old address", category: "contact"),
        ]
        sharing.contents["g5"] = SharedContent(itemID: "x1", name: "Insurance card", category: "insurance", fields: [ItemFieldView(fieldID: "f1", label: "Policy", kind: "text", value: .text("P-42"))], notes: nil, usesLeft: 2)
        sharing.refusals["g6"] = "revoked"
        let vm = await sharedVM()
        #expect(vm.state.received.count == 2)
        #expect(!sharing.calls.contains { $0.hasPrefix("fetch") })
        vm.fetch("g5")
        await vm.settle()
        #expect(vm.state.opened["g5"]?.fields.first?.value == .text("P-42"))
        #expect(!"\(vm.state)".contains("P-42") && !String(reflecting: vm.state).contains("P-42"), "never printed")
        vm.fetch("g6")
        await vm.settle()
        #expect(vm.state.refused["g6"] == "revoked")
        vm.hide()
        #expect(vm.state.opened.isEmpty)
    }

    /// §10.12 `grant.request`: a category entry the other member answers.
    @Test func aConnectionIsAskedForACategory() async {
        let vm = await sharedVM()
        vm.openAsk(true)
        vm.setAsk(GrantAskForm(category: "insurance", label: "Your insurance card", reason: "For the trip"))
        vm.sendAsk()
        await vm.settle()
        let made = sharing.requests.first
        #expect(sharing.requests.count == 1 && made?.connectionID == "c1" && made?.category == "insurance")
        #expect(made?.label == "Your insurance card" && made?.reason == "For the trip")
        #expect(vm.state.ask == nil && vm.state.asked)
    }

    /// 0.23.0 §10.12: a `rate_limited` refusal says when the item can be fetched again.
    @Test func aRateLimitedFetchSaysWhenToTryAgain() async {
        sharing.received = [GrantView(grantID: "g6", connectionID: "c1", direction: .received, itemRef: "x2", name: "Card", category: "insurance", perHour: 5)]
        sharing.refusals["g6"] = "rate_limited"
        sharing.retryAfter["g6"] = 720
        let at = now
        let vm = await sharedVM(now: { at })
        #expect(vm.state.received.first?.perHour == 5)
        vm.fetch("g6")
        await vm.settle()
        #expect(vm.state.refused["g6"] == "rate_limited" && vm.state.retryAt["g6"] == now.addingTimeInterval(720))
        // Rounded up to whole minutes, in hours from 90 minutes.
        #expect(RetryIn.of(720) == .init(scale: .minutes, count: 12))
        #expect(RetryIn.of(1) == .init(scale: .minutes, count: 1) && RetryIn.of(0) == .init(scale: .minutes, count: 1))
        #expect(RetryIn.of(61) == .init(scale: .minutes, count: 2) && RetryIn.of(89 * 60) == .init(scale: .minutes, count: 89))
        #expect(RetryIn.of(90 * 60) == .init(scale: .hours, count: 2) && RetryIn.of(86_400) == .init(scale: .hours, count: 24))
        // Another refusal has no retry.
        sharing.refusals["g6"] = "revoked"
        sharing.retryAfter.removeAll()
        vm.fetch("g6")
        await vm.settle()
        #expect(vm.state.retryAt["g6"] == nil)
    }

}

extension SharingViewModelsTests {
    // MARK: - Beyond Android's tests

    /// IOS-PLAN §4.7: a lock, the hold or a wipe drops what was fetched and the form being typed.
    @Test func whenTheVaultIsClearedWhatWasFetchedIsDropped() async {
        sharing.received = [GrantView(grantID: "g5", connectionID: "c1", direction: .received, itemRef: "x1", name: "Card", category: "insurance")]
        sharing.contents["g5"] = SharedContent(itemID: "x1", name: "Card", category: "insurance", fields: [], notes: nil, usesLeft: nil)
        sharing.refusals["g6"] = "rate_limited"
        sharing.retryAfter["g6"] = 60
        let vm = await sharedVM()
        vm.fetch("g5")
        await vm.settle()
        vm.fetch("g6")
        await vm.settle()
        vm.openAsk(true)
        #expect(vm.state.opened["g5"] != nil && vm.state.retryAt["g6"] != nil && vm.state.ask != nil)
        items.clear()
        #expect(await eventually { vm.state.opened.isEmpty })
        #expect(vm.state.refused.isEmpty && vm.state.retryAt.isEmpty && vm.state.ask == nil)
    }

    @Test func aFetchOnItsWayWhenTheVaultIsClearedIsNotKept() async {
        sharing.received = [GrantView(grantID: "g5", connectionID: "c1", direction: .received, itemRef: "x1", name: "Card", category: "insurance")]
        sharing.contents["g5"] = SharedContent(itemID: "x1", name: "Card", category: "insurance", fields: [], notes: nil, usesLeft: nil)
        let vm = await sharedVM()
        let hold = TestHold()
        sharing.fetchHold = hold
        vm.fetch("g5")
        #expect(await eventually { hold.count == 1 })
        items.clear()
        #expect(await eventually { vm.state.fetching == nil })
        hold.releaseAll()
        await vm.settle()
        #expect(vm.state.opened.isEmpty)
    }

    @Test func whenTheVaultIsClearedTheRuleDraftIsDroppedAndTheEditorCloses() async {
        let vm = await ruleVM()
        vm.selectTag("medical")
        vm.setUses("3")
        #expect(vm.state.dirty && !vm.closed)
        items.clear()
        #expect(await eventually { vm.closed })
        #expect(vm.state.draft.tags.isEmpty && vm.state.usesText.isEmpty && !vm.state.dirty)
    }

    /// A dry run that answers late for a draft since replaced is never shown; the latest draft's answer is.
    @Test func aSlowPreviewForAReplacedDraftIsNeverApplied() async {
        let stale = RulePreview(matches: [], total: 1)
        let latest = RulePreview(matches: [], total: 2)
        let vm = await ruleVM()
        let hold = TestHold()
        sharing.previewHold = hold
        sharing.preview = stale
        vm.selectTag("medical")
        #expect(await eventually { hold.count == 1 })
        // The first dry run is waiting; a newer draft replaces it, and the vault now answers the new one.
        sharing.preview = latest
        vm.setMode(.auto)
        #expect(await eventually { hold.count == 2 })
        // The latest answer comes first, the stale one after it.
        hold.release(1)
        #expect(await eventually { vm.state.preview?.total == 2 })
        hold.release(0)
        await vm.settle()
        #expect(vm.state.preview?.total == 2 && !vm.state.previewing)
        #expect(sharing.calls.count { $0 == "preview" } == 2)
    }

    @Test func digitsOfOtherScriptsReadAsAscii() async {
        let vm = await ruleVM()
        vm.selectTag("medical")
        vm.setUses("\u{0663}\u{0664}x") // Arabic-Indic 3, 4
        #expect(vm.state.usesText == "34" && vm.state.draft.uses == 34)
        vm.setPerHour("\u{FF15}\u{00BD}") // full-width 5; a vulgar fraction is no digit
        #expect(vm.state.perHourText == "5")
    }

    @Test func giveUpRemovesAReceivedGrantAndItsOpenedContent() async {
        let g = GrantView(grantID: "g5", connectionID: "c1", direction: .received, itemRef: "x1", name: "Card", category: "insurance")
        sharing.received = [g]
        sharing.contents["g5"] = SharedContent(itemID: "x1", name: "Card", category: "insurance", fields: [], notes: nil, usesLeft: nil)
        let vm = await sharedVM()
        vm.fetch("g5")
        await vm.settle()
        #expect(vm.state.opened["g5"] != nil)
        vm.askGiveUp(g)
        vm.giveUp()
        await vm.settle()
        #expect(sharing.calls.contains("revoke:g5") && vm.state.opened.isEmpty && vm.state.confirmGiveUp == nil)
        #expect(vm.state.received.first?.active == false)
    }

    @Test func aFailedAskKeepsTheFormAndSaysWhy() async {
        sharing.fail["requestGrant"] = VaultFailure(.limit, code: "limit")
        let vm = await sharedVM(ask: true)
        #expect(vm.state.ask == GrantAskForm())
        vm.setAsk(GrantAskForm(category: "insurance"))
        vm.sendAsk()
        await vm.settle()
        #expect(vm.state.error == .limit && vm.state.ask == GrantAskForm(category: "insurance") && !vm.state.asked)
    }

    @Test func aFailedLoadIsShownAndAnotherFetchWaitsForTheFirst() async {
        sharing.fail["grants"] = VaultFailure(.notFound)
        let vm = await sharedVM()
        #expect(vm.state.error == .notFound && !vm.state.loading)
        vm.fetch("g1")
        vm.fetch("g2")
        await vm.settle()
        #expect(sharing.calls.count { $0.hasPrefix("fetch") } == 1)
    }

    @Test func theExpiryAndRetryWords() {
        #expect(ItemsText.expiry(.never) == "Never" && ItemsText.expiry(.threeMonths) == ItemsStrings.ruleExpiryThreeMonths)
        #expect(ItemsText.retry(until: now.addingTimeInterval(720), now: now) == "Try again in 12 minutes.")
        #expect(ItemsText.retry(until: now.addingTimeInterval(60), now: now) == "Try again in 1 minute.")
        #expect(ItemsText.retry(until: now.addingTimeInterval(7_200), now: now) == "Try again in 2 hours.")
        #expect(ItemsStrings.grantUsesLeft(1) == "1 fetch left" && ItemsStrings.grantUsesLeft(2) == "2 fetches left")
    }
}

private func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso) ?? Date(timeIntervalSince1970: 0)
}

// swiftlint:enable line_length
