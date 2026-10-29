import Foundation
import Testing
import VettIDData
@testable import VettIDItems

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The sharing screens' sentences and the ask form's byte caps. Mirrors the text cases of vettid-android's
/// `SharingScreensTest`.
@Suite struct SharingTextsTests {
    let utc = TimeZone(identifier: "UTC")!
    let address = ShareRule(ruleID: "r1", version: 1, connectionID: "c1", tags: ["address"], mode: .auto, included: ["i1"])
    let license = ShareRule(ruleID: "r2", version: 1, connectionID: "c1", tags: ["drivers-license"], uses: 5, expiresAt: Date(timeIntervalSince1970: 1_798_718_400), included: ["i2"], pending: ["i3"])
    let travel = ShareRule(ruleID: "r3", version: 1, connectionID: "c1", tags: ["drivers-license", "travel"], match: .all, mode: .auto, uses: 1, included: ["i2"])

    @Test func theManageScreenReadsEveryRuleWithItsOwnSettings() {
        let state = { () -> ConnectionSharingState in
            var s = ConnectionSharingState(connectionID: "c1", connectionName: "Dana Lee")
            s.rules = [address, license, travel]
            s.loading = false
            return s
        }()
        #expect(ItemsText.ruleMode(address.mode) == "Shared automatically" && ItemsText.ruleMode(license.mode) == "Asks you each time")
        #expect(ItemsText.ruleLimits(address, zone: utc) == "no fetch limit · no end date")
        #expect(ItemsText.ruleLimits(license, zone: utc).hasPrefix("up to 5 fetches of each item · until "))
        #expect(ItemsStrings.ruleMatchAllShort.hasPrefix("All of these tags"))
        // 0.23.0: rules named by their tags, and an `auto` rule asks first where an `ask` rule overlaps it.
        let names = RuleNames.of(state.rules)
        let overlaps = state.overlaps
        #expect(ItemsText.overlap(license, overlaps["r2"] ?? [], names: names) == "Overlaps your “drivers-license + travel” rule")
        #expect(ItemsText.overlap(travel, overlaps["r3"] ?? [], names: names) == "Asks you first for the items your “drivers-license” rule also covers")
        #expect(ItemsText.overlap(address, overlaps["r1"] ?? [], names: names) == nil)
    }

    @Test func rateLimitsAreInTheRulesSummary() {
        let limited = ShareRule(ruleID: "r7", version: 1, connectionID: "c1", tags: ["medical"], perHour: 5, perDay: 20)
        #expect(ItemsText.ruleLimits(limited, zone: utc) == "up to 5 an hour · up to 20 a day · no end date")
        let counted = ShareRule(ruleID: "r8", version: 1, connectionID: "c1", tags: ["medical"], uses: 3, perDay: 2, included: ["a", "b"], pending: ["c"])
        #expect(ItemsText.ruleLimits(counted, zone: utc).hasPrefix("up to 3 fetches of each item · up to 2 a day · no end date"))
        #expect(ItemsText.ruleCounts(counted) == "2 shared · 1 waiting · 0 declined")
    }

    @Test func aRuleIsNamedByItsTagsWithWhatTellsTwoApart() {
        let a = ShareRule(ruleID: "a", version: 1, connectionID: "c1", tags: ["medical"], mode: .ask)
        let b = ShareRule(ruleID: "b", version: 1, connectionID: "c1", tags: ["medical"], mode: .auto)
        let c = ShareRule(ruleID: "c", version: 1, connectionID: "c1", tags: ["id", "travel"], match: .any)
        let names = RuleNames.of([a, b, c])
        #expect(ItemsText.ruleNamed(a, names: names) == "your “medical” rule (asks first)")
        #expect(ItemsText.ruleNamed(b, names: names) == "your “medical” rule (shares automatically)")
        #expect(ItemsText.ruleNamed(c, names: names) == "your “id or travel” rule")
        #expect(ItemsText.ruleNamed(c) == "your “id or travel” rule")
    }

    @Test func theEditorOffersEveryEnd() {
        let labels = (RuleExpiry.presets + [.custom]).map { ItemsText.expiryChoice($0, at: nil) }
        #expect(labels == ["Never", "1 day", "1 week", "1 month", "3 months", "1 year", "Custom…"])
        #expect(ItemsText.expiryChoice(.keep, at: nil) == "Never")
        #expect(ItemsText.expiryChoice(.keep, at: license.expiresAt, zone: utc).hasPrefix("until "))
        #expect(ItemsStrings.ruleEndBad == "Pick a time in the future, at most 10 years ahead.")
        #expect(ItemsStrings.ruleEndsAt("x") == "Ends x (your time)")
    }

    @Test func theEditorShowsTheOtherRulesCoveringTheSameTagOrItem() {
        let line = ItemsText.overlapLine(travel, draftTags: ["drivers-license"], matched: ["i2", "i4"])
        #expect(line == "Shared automatically · also names drivers-license · 1 of these items is in it")
        #expect(ItemsStrings.ruleOverlapNote.contains("asking wins"))
        #expect(!ItemsStrings.ruleOverlapNote.contains("Each rule works on its own"))
    }

    @Test func theDryRunExplainsWhyAnAutoRuleAsksFirst() {
        let medical = ShareRule(ruleID: "r5", version: 1, connectionID: "c1", tags: ["medical"])
        let ask = RuleMatch(itemID: "i1", name: "Allergies", category: "medical", sensitivity: .data, outcome: RuleMatch.outcomeAsk, askRuleID: "r5")
        let include = RuleMatch(itemID: "i4", name: "Bank", category: "bank_account", sensitivity: .data, outcome: RuleMatch.outcomeInclude)
        let p = RulePreview(matches: [ask, include], total: 2)
        #expect(ItemsText.previewTotal(p, mode: .auto) == "2 items match: 1 shared at once, 1 asks you first.")
        #expect(ItemsText.matchNote(ask, rules: [medical], names: RuleNames.of([medical])) == "Asks you first because your “medical” rule covers it")
        #expect(ItemsText.matchNote(include, rules: [medical], names: [:]) == "Shared at once")
        // Without outcomes: from the rule's mode, and what an item is now.
        let plain = RulePreview(matches: [RuleMatch(itemID: "i2", name: "Driver’s license", category: "identity_document", sensitivity: .data, state: "included")], total: 3)
        #expect(ItemsText.previewTotal(plain, mode: .ask) == ItemsStrings.rulePreviewAsk(3) && ItemsText.previewTotal(plain, mode: .auto) == ItemsStrings.rulePreviewAuto(3))
        #expect(ItemsText.matchNote(plain.matches[0], rules: [], names: [:])?.contains("Already shared") == true)
        #expect(ItemsText.matchNote(RuleMatch(itemID: "i4", name: "Library card", category: "membership", sensitivity: .data), rules: [], names: [:]) == nil)
    }

    /// VAULT-MESSAGING 0.76.0 §10.8: a custom category is the sender's text, so it is isolated in the line.
    @Test func aReceivedCustomCategoryIsIsolatedARecommendedOneIsNot() {
        let custom = GrantView(grantID: "g7", connectionID: "c1", direction: .received, itemRef: "x3", name: "Card", category: "home_lab")
        #expect(ItemsText.receivedLabel(custom, category: nil, name: "Dana Lee").hasPrefix("\u{2068}Home lab\u{2069} · "))
        #expect(ItemsText.receivedLabel(custom, category: "insurance", name: "Dana Lee").hasPrefix("\u{2068}") == false)
    }

    @Test func aReceivedGrantShowsItsLimitsAndARefusalWhenToTryAgain() {
        let g = GrantView(grantID: "g6", connectionID: "c1", direction: .received, itemRef: "x2", name: "Card", category: "insurance", perHour: 5, perDay: 1)
        let label = ItemsText.receivedLabel(g, category: nil, name: "Dana Lee")
        #expect(label.contains("shared by") && label.contains("up to 5 times an hour · up to 1 time a day"))
        let now = Date(timeIntervalSince1970: 1_791_384_000)
        #expect(ItemsText.retry(until: now.addingTimeInterval(11 * 60 + 30), now: now) == "Try again in 12 minutes.")
        #expect(ItemsText.retry(until: now.addingTimeInterval(2 * 3_600), now: now) == "Try again in 2 hours.")
        #expect(ItemsText.refusal("rate_limited", name: "Dana Lee").contains("Dana Lee"))
    }

    @Test func aRequestIsReadAsTheMemberAskedForIt() {
        #expect(ItemsText.askEntry(GrantAskEntry(kind: "category", ref: "insurance", label: "My card")) == "My card")
        #expect(ItemsText.askEntry(GrantAskEntry(kind: "category", ref: "insurance")) == ItemsStrings.askEntryCategory("Insurance"))
        #expect(ItemsText.askEntry(GrantAskEntry(kind: "item", ref: "i1")) == ItemsStrings.askEntryItem)
        #expect(ItemsText.askState("approved") == ItemsStrings.askStateGranted && ItemsText.askState("granted") == ItemsStrings.askStateGranted)
        #expect(ItemsText.askState("denied") == ItemsStrings.askStateDenied && ItemsText.askState("pending") == ItemsStrings.askStatePending)
        #expect(ItemsText.sharingName(nil) == ItemsStrings.sharingThisConnection && ItemsText.sharingName("Dana Lee").contains("Dana Lee"))
    }

    // MARK: - The ask form's byte caps

    @Test func theCapCountsBytesAndNeverSplitsACharacter() {
        #expect(Utf8Cap.prefix("hello", bytes: 10) == "hello" && Utf8Cap.prefix("hello", bytes: 3) == "hel" && Utf8Cap.prefix("", bytes: 0) == "")
        // Two bytes each: 4 bytes hold two, 5 bytes still two.
        #expect(Utf8Cap.prefix("éééé", bytes: 4) == "éé" && Utf8Cap.prefix("éééé", bytes: 5) == "éé")
        // Three bytes; four bytes; a family emoji (one character, 25 bytes) is kept whole or not at all.
        #expect(Utf8Cap.prefix("日本語", bytes: 7) == "日本" && Utf8Cap.prefix("😀😀", bytes: 7) == "😀")
        let family = "👨‍👩‍👧‍👦"
        #expect(family.utf8.count == 25 && Utf8Cap.prefix("a" + family, bytes: 20) == "a" && Utf8Cap.prefix("a" + family, bytes: 26) == "a" + family)
        // A letter with a combining accent is one character.
        #expect(Utf8Cap.prefix("e\u{301}e\u{301}", bytes: 4) == "e\u{301}")
    }

    @Test func theLabelStopsAt128BytesAndTheReasonAt256() {
        #expect(SharingManager.maxLabel == 128 && SharingManager.maxReason == 256)
        let wide = String(repeating: "é", count: 100)
        #expect(Utf8Cap.label(wide).utf8.count == 128 && Utf8Cap.label(wide).count == 64)
        #expect(Utf8Cap.reason(wide + wide + wide).utf8.count == 256)
        // 128 one-byte characters pass whole; 129 are cut to 128.
        #expect(Utf8Cap.label(String(repeating: "a", count: 128)).count == 128 && Utf8Cap.label(String(repeating: "a", count: 129)).count == 128)
        // A cut text is accepted by the request's own check.
        #expect(Utf8Cap.label(String(repeating: "日", count: 100)).utf8.count <= SharingManager.maxLabel)
    }
}

// swiftlint:enable line_length
