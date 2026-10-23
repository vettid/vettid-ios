import Foundation
import VettIDData

// The sharing screens' sentences, over the table's accessors (``ItemsStrings``): a rule's mode, limits and overlaps, the dry
// run's lines, a received grant's line. Mirrors the helpers of vettid-android `SharingScreens.kt` and `RuleEditScreen.kt`.
public extension ItemsText {
    /// The connection's name inside a sentence (bidi-isolated, §10.8), or a neutral placeholder.
    static func sharingName(_ name: String?) -> String {
        name.map(AccountNames.isolate) ?? ItemsStrings.sharingThisConnection
    }

    /// A calendar day as lists show it (vettid-android `Times.dayLabel`), in [zone].
    static func dayLabel(_ d: Date, zone: TimeZone = .current) -> String {
        d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: zone))
    }

    /// A full date and time (vettid-android `Times.full`), in [zone].
    static func fullTime(_ d: Date, zone: TimeZone = .current) -> String {
        d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone))
    }

    /// "Shared automatically" or "Asks you each time" (§10.12 `mode`).
    static func ruleMode(_ m: ShareMode) -> String {
        m == .auto ? ItemsStrings.ruleSummaryAuto : ItemsStrings.ruleSummaryAsk
    }

    /// The rule's limits and end: "up to 5 fetches of each item · up to 5 an hour · up to 20 a day · until Dec 31, 2026", or
    /// "no fetch limit · no end date" (0.23.0: per hour and per day of all its items together).
    static func ruleLimits(_ r: ShareRule, zone: TimeZone = .current) -> String {
        let uses = r.uses.map(ItemsStrings.ruleUsesPlural) ?? (r.perHour == nil && r.perDay == nil ? ItemsStrings.ruleNoLimit : nil)
        let end = r.expiresAt.map { ItemsStrings.ruleUntil(dayLabel($0, zone: zone)) } ?? ItemsStrings.ruleNoEnd
        return [uses, r.perHour.map(ItemsStrings.rulePerHourSummary), r.perDay.map(ItemsStrings.rulePerDaySummary), end]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "3 shared · 1 waiting · 0 declined" (a rule's items).
    static func ruleCounts(_ r: ShareRule) -> String {
        let parts = [
            ItemsStrings.ruleIncluded(r.included.count), ItemsStrings.rulePending(r.pending.count),
            ItemsStrings.ruleDeclined(r.declined.count),
        ]
        return parts.joined(separator: " · ")
    }

    /// A rule as the member reads it (§10.12, owner's review of #181): by its tags, "your “medical” rule" ("medical + id" for
    /// all, "medical or id" for any), with what tells it apart from another rule of the subject that reads the same.
    static func ruleNamed(_ r: ShareRule, names: [String: RuleNames.Name] = [:], zone: TimeZone = .current) -> String {
        let n = names[r.ruleID] ?? RuleNames.Name(text: RuleNames.text(r))
        switch n.qualifier {
        case nil: return ItemsStrings.ruleName(n.text)
        case .mode(let m)?: return m == .ask ? ItemsStrings.ruleNameAsks(n.text) : ItemsStrings.ruleNameAuto(n.text)
        case .ends(let at)?:
            return at.map { ItemsStrings.ruleNameUntil(n.text, dayLabel($0, zone: zone)) } ?? ItemsStrings.ruleNameNoEnd(n.text)
        }
    }

    /// How a rule meets the subject's other rules (§10.12 Overlapping rules, 0.23.0): an `auto` rule "Asks you first for the
    /// items your “medical” rule also covers" when an `ask` rule overlaps it; otherwise "Overlaps your “x” rule". Nil without
    /// overlaps.
    static func overlap(_ r: ShareRule, _ overlaps: [ShareRule], names: [String: RuleNames.Name], zone: TimeZone = .current) -> String? {
        if overlaps.isEmpty { return nil }
        let askers = RuleOverlaps.asksFirst(r.mode, overlaps)
        let others = overlaps.filter { o in !askers.contains { $0.ruleID == o.ruleID } }
        let list = { (rules: [ShareRule]) in rules.map { ruleNamed($0, names: names, zone: zone) }.joined(separator: ", ") }
        return [
            askers.isEmpty ? nil : ItemsStrings.ruleAsksFirstFor(list(askers)),
            others.isEmpty ? nil : ItemsStrings.ruleOverlaps(list(others)),
        ].compactMap { $0 }.joined(separator: ". ")
    }

    /// An overlapping rule's line in the editor: its mode, the tags it shares with the draft, and how many of the matched
    /// items it holds.
    static func overlapLine(_ o: ShareRule, draftTags: [String], matched: [String]) -> String {
        let common = RuleOverlaps.sharedTags(draftTags, o)
        let items = RuleOverlaps.sharedItems(matched, o).count
        return [
            ruleMode(o.mode),
            common.isEmpty ? nil : ItemsStrings.ruleOverlapTags(common.joined(separator: ", ")),
            items > 0 ? ItemsStrings.ruleOverlapItems(items) : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// "3 items match: 1 shared at once, 2 ask you first." (0.23.0 `outcome`s), or as before from the rule's mode.
    static func previewTotal(_ p: RulePreview, mode: ShareMode) -> String {
        let include = p.matches.filter { $0.outcome == RuleMatch.outcomeInclude }.count
        let ask = p.matches.filter { $0.outcome == RuleMatch.outcomeAsk }.count
        if include + ask == 0 { return mode == .ask ? ItemsStrings.rulePreviewAsk(p.total) : ItemsStrings.rulePreviewAuto(p.total) }
        let parts = [
            include > 0 ? ItemsStrings.rulePreviewOutcomeInclude(include) : nil,
            ask > 0 ? ItemsStrings.rulePreviewOutcomeAsk(ask) : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        return ItemsStrings.rulePreviewOutcomes(ItemsStrings.rulePreviewMatch(p.total), parts)
    }

    /// What saving does to one matched item (0.23.0), or what it is now in this rule.
    static func matchNote(_ m: RuleMatch, rules: [ShareRule], names: [String: RuleNames.Name], zone: TimeZone = .current) -> String? {
        let asker = m.askRuleID.flatMap { id in rules.first { $0.ruleID == id } }
        if m.outcome == RuleMatch.outcomeAsk {
            return asker.map { ItemsStrings.ruleOutcomeAskBecause(ruleNamed($0, names: names, zone: zone)) } ?? ItemsStrings.ruleOutcomeAsk
        }
        if m.outcome == RuleMatch.outcomeInclude { return ItemsStrings.ruleOutcomeInclude }
        switch m.state {
        case "included": return ItemsStrings.ruleStateIncluded
        case "pending": return ItemsStrings.ruleStatePending
        case "declined": return ItemsStrings.ruleStateDeclined
        default: return nil
        }
    }

    /// A rule end's choice as the editor lists it; an existing rule's own end ([at], kept) reads "until <day>".
    static func expiryChoice(_ e: RuleExpiry, at: Date?, zone: TimeZone = .current) -> String {
        if e == .keep { return at.map { ItemsStrings.ruleUntil(dayLabel($0, zone: zone)) } ?? ItemsStrings.ruleExpiryNever }
        return expiry(e)
    }

    /// A given grant's line: how it came, uses left and its end.
    static func givenLine(_ g: GrantView, zone: TimeZone = .current) -> String {
        [
            g.ruleID != nil ? ItemsStrings.grantByRule : ItemsStrings.grantOneOff,
            g.usesLeft.map(ItemsStrings.grantUsesLeft),
            g.expiresAt.map { ItemsStrings.ruleUntil(fullTime($0, zone: zone)) },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// A received grant's line: its category, whose it is, uses left, the rule's rate limits (0.23.0) and its end.
    static func receivedLabel(_ g: GrantView, category: String?, name: String, zone: TimeZone = .current) -> String {
        [
            Self.category(category ?? g.category),
            ItemsStrings.sharedBy(name),
            g.usesLeft.map(ItemsStrings.grantUsesLeft),
            g.perHour.map(ItemsStrings.grantPerHour),
            g.perDay.map(ItemsStrings.grantPerDay),
            g.expiresAt.map { ItemsStrings.ruleUntil(fullTime($0, zone: zone)) },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// An entry as the member asked for it (§10.12 `requested`, 0.21.0: exactly as sent): their own words, else the category.
    static func askEntry(_ e: GrantAskEntry) -> String {
        if let label = e.label { return label }
        return e.kind == "category" ? ItemsStrings.askEntryCategory(category(e.ref)) : ItemsStrings.askEntryItem
    }
}
