#if os(iOS)
import Foundation
import VettIDConnections
import VettIDData

/// The sentences of the connection page's sharing cards, over ``ConnectStrings``: a rule's mode, limits and counts, how it
/// meets the other rules, a given and a received grant's line. Mirrors the helpers of vettid-android
/// `ConnectionSharingCards.kt`.
enum SharingCardTexts {
    /// "Shared automatically" or "Asks you each time" (§10.12 `mode`).
    static func mode(_ m: ShareMode) -> String { m == .auto ? ConnectStrings.shareRuleAuto : ConnectStrings.shareRuleAsk }

    /// "Items with all of these tags" or "...any..." (a rule of several tags).
    static func match(_ m: TagMatch) -> String { m == .all ? ConnectStrings.shareRuleAll : ConnectStrings.shareRuleAny }

    /// The rule's limits and end: "up to 5 fetches of each item · up to 5 an hour · up to 20 a day · until Dec 31, 2026", or
    /// "no fetch limit · no end date" (0.23.0: per hour and per day of all its items together).
    static func limits(_ r: ShareRule, zone: TimeZone = .current) -> String {
        let uses = r.uses.map(ConnectStrings.shareUses)
            ?? (r.perHour == nil && r.perDay == nil ? ConnectStrings.shareNoLimit : nil)
        let end = r.expiresAt.map { ConnectStrings.shareUntil(ConnectTimes.dayLabel($0, zone: zone)) } ?? ConnectStrings.shareNoEnd
        return [uses, r.perHour.map(ConnectStrings.sharePerHour), r.perDay.map(ConnectStrings.sharePerDay), end]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "2 items shared now · 1 waiting for you".
    static func counts(_ r: ShareRule) -> String {
        [ConnectStrings.shareRuleIncluded(r.included.count), r.pending.isEmpty ? nil : ConnectStrings.shareRulePending(r.pending.count)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// A rule named by its tags (§10.12): "your “medical” rule", told apart when two read the same.
    static func named(_ r: ShareRule, names: [String: RuleNames.Name], zone: TimeZone = .current) -> String {
        let n = names[r.ruleID] ?? RuleNames.Name(text: RuleNames.text(r))
        switch n.qualifier {
        case nil: return ConnectStrings.ruleName(n.text)
        case .mode(let m)?: return m == .ask ? ConnectStrings.ruleNameAsks(n.text) : ConnectStrings.ruleNameAuto(n.text)
        case .ends(let at)?:
            return at.map { ConnectStrings.ruleNameUntil(n.text, ConnectTimes.dayLabel($0, zone: zone)) }
                ?? ConnectStrings.ruleNameNoEnd(n.text)
        }
    }

    /// How a rule meets this connection's other rules (§10.12 Overlapping rules, 0.23.0): an `auto` rule "Asks you first for
    /// the items your “medical” rule also covers" when an `ask` rule overlaps it; otherwise "Overlaps your “x” rule". Nil
    /// without overlaps.
    static func overlap(_ r: ShareRule, _ overlaps: [ShareRule], names: [String: RuleNames.Name], zone: TimeZone = .current) -> String? {
        if overlaps.isEmpty { return nil }
        let askers = RuleOverlaps.asksFirst(r.mode, overlaps)
        let others = overlaps.filter { o in !askers.contains { $0.ruleID == o.ruleID } }
        let list = { (rules: [ShareRule]) in rules.map { named($0, names: names, zone: zone) }.joined(separator: ", ") }
        return [
            askers.isEmpty ? nil : ConnectStrings.shareRuleAsksFirstFor(list(askers)),
            others.isEmpty ? nil : ConnectStrings.shareRuleOverlaps(list(others)),
        ].compactMap { $0 }.joined(separator: ". ")
    }

    /// An item of the member's the connection can fetch now: how it was given, uses left and its end.
    static func givenLine(_ g: GrantView, zone: TimeZone = .current) -> String {
        [
            g.ruleID != nil ? ConnectStrings.shareByRule : ConnectStrings.shareOneOff,
            g.usesLeft.map(ConnectStrings.shareUsesLeft),
            g.expiresAt.map { ConnectStrings.shareUntil(ConnectTimes.full($0, zone: zone)) },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// An item the connection shares with the member: marked as theirs, uses left, the rule's rate limits and its end.
    /// [name]: the connection's first name, bidi-isolated; nil before the names arrived.
    static func receivedLine(_ g: GrantView, name: String?, zone: TimeZone = .current) -> String {
        [
            name.map(ConnectStrings.shareTheirs) ?? ConnectStrings.theirsUnnamed,
            g.usesLeft.map(ConnectStrings.shareUsesLeft),
            g.perHour.map(ConnectStrings.shareReceivedPerHour),
            g.perDay.map(ConnectStrings.shareReceivedPerDay),
            g.expiresAt.map { ConnectStrings.shareUntil(ConnectTimes.full($0, zone: zone)) },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private static func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A given item's name: "Deleted item" when the vault no longer has it.
    static func givenName(_ g: GrantView) -> String { blank(g.name) ? ConnectStrings.shareDeletedItem : g.name }

    /// A received item's name, else the label it was shared under, else "Deleted item".
    static func receivedName(_ g: GrantView) -> String { blank(g.name) ? (g.label ?? ConnectStrings.shareDeletedItem) : g.name }
}
#endif
