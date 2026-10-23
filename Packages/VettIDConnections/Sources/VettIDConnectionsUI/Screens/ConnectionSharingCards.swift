#if os(iOS)
import SwiftUI
import VettIDConnections
import VettIDData
import VettIDUI

/// "You share with <First>": what goes out of the member's vault to this connection (VAULT-ITEMS §6, §10.12): every share
/// rule for it as a row of its own (tags, ask or automatic, its fetch limit and end, what it shares now, the other rules
/// covering the same tags or items), each opening its editor or deleted (confirmed); "Add a rule" (up to 64, §10.12
/// `share_rules_subject`); and the items it can fetch now. Gold, as the member's own avatar: it is the member's data. Mirrors
/// vettid-android `OutgoingSharingCard`.
struct OutgoingSharingCard: View {
    @Environment(\.vettIDColors) private var colors
    let sharing: DetailSharing
    /// The connection's first name (not yet isolated); nil before the names arrived.
    let first: String?
    let onShare: @MainActor () -> Void
    let onOpenRule: @MainActor (String) -> Void
    let onManage: @MainActor () -> Void
    let onDeleteRule: @MainActor (ShareRule) -> Void

    private var name: String? { first.map(AccountNames.isolate) }

    var body: some View {
        DirectionCard(
            accent: colors.primary, badgeFill: colors.primaryContainer, onBadge: colors.onPrimaryContainer, icon: .outbox,
            title: name.map(ConnectStrings.shareOutTitle) ?? ConnectStrings.shareOutTitleUnnamed, count: sharing.outgoingCount,
            countLabel: ConnectStrings.shareOutCount(sharing.outgoingCount), identifier: "sharing_out"
        ) {
            if sharing.failed {
                Muted(text: ConnectStrings.shareUnavailable, identifier: "sharing_out_failed")
            } else if sharing.loaded && sharing.outgoingEmpty {
                Muted(
                    text: name.map(ConnectStrings.shareOutEmpty) ?? ConnectStrings.shareOutEmptyUnnamed, identifier: "sharing_out_empty"
                )
            }
            if !sharing.rules.isEmpty { rules }
            if !sharing.given.isEmpty {
                SubHeading(text: ConnectStrings.shareOutItems)
                ForEach(sharing.given) { GivenLine(grant: $0) }
            }
            Spacer().frame(height: Spacing.s)
            if sharing.atRuleLimit {
                Muted(text: VaultLimit(Self.limitName, max: Int64(RuleDraft.maxRulesPerSubject)).message, identifier: "sharing_out_limit")
            }
            SecondaryButton(ConnectStrings.shareOutAction, action: onShare)
                .disabled(sharing.atRuleLimit)
                .accessibilityIdentifier("sharing_out_share")
            if !sharing.outgoingEmpty {
                TextAction(label: ConnectStrings.shareOutManage, identifier: "sharing_out_manage", action: onManage)
            }
        }
    }

    /// The named limit of rules per connection (§10.12).
    static let limitName = "share_rules_subject"

    @ViewBuilder private var rules: some View {
        SubHeading(text: ConnectStrings.shareOutRules)
        let overlaps = sharing.overlaps
        let names = RuleNames.of(sharing.rules)
        ForEach(Array(sharing.rules.enumerated()), id: \.element.ruleID) { i, r in
            if i > 0 { Divider().overlay(colors.outlineVariant.color) }
            RuleLine(rule: r, overlaps: overlaps[r.ruleID] ?? [], names: names, onOpen: onOpenRule, onDelete: onDeleteRule)
        }
    }
}

/// "<First> shares with you": what comes in from the connection's vault (§10.12 received grants): read-only and labelled as
/// theirs, in a neutral accent. "Ask for something" is the `grant.request` flow. Mirrors vettid-android `IncomingSharingCard`.
struct IncomingSharingCard: View {
    @Environment(\.vettIDColors) private var colors
    let sharing: DetailSharing
    let first: String?
    let onAsk: @MainActor () -> Void
    let onOpen: @MainActor () -> Void

    private var name: String? { first.map(AccountNames.isolate) }

    var body: some View {
        DirectionCard(
            accent: colors.secondary, badgeFill: colors.secondaryContainer, onBadge: colors.onSecondaryContainer, icon: .inbox,
            title: name.map(ConnectStrings.shareInTitle) ?? ConnectStrings.shareInTitleUnnamed, count: sharing.incomingCount,
            countLabel: ConnectStrings.shareInCount(sharing.incomingCount), identifier: "sharing_in"
        ) {
            if sharing.failed {
                Muted(text: ConnectStrings.shareUnavailable, identifier: "sharing_in_failed")
            } else if sharing.loaded && sharing.incomingEmpty {
                Muted(text: name.map(ConnectStrings.shareInEmpty) ?? ConnectStrings.shareInEmptyUnnamed, identifier: "sharing_in_empty")
            }
            ForEach(sharing.received) { ReceivedLine(grant: $0, name: name, onOpen: onOpen) }
            if !sharing.asked.isEmpty {
                Muted(text: ConnectStrings.shareInAsked(sharing.asked.count), identifier: "sharing_in_asked")
            }
            Spacer().frame(height: Spacing.s)
            SecondaryButton(ConnectStrings.shareInAction, action: onAsk).accessibilityIdentifier("sharing_in_ask")
            if !sharing.incomingEmpty {
                TextAction(label: ConnectStrings.shareInOpen, identifier: "sharing_in_open", action: onOpen)
            }
        }
    }
}

/// A card with a direction: an accent edge, the direction's icon, a heading and the count of items it holds. Mirrors
/// vettid-android `DirectionCard`.
struct DirectionCard<Content: View>: View {
    @Environment(\.vettIDColors) private var colors
    let accent: ThemeColor
    let badgeFill: ThemeColor
    let onBadge: ThemeColor
    let icon: VettIDSymbol
    let title: String
    let count: Int
    let countLabel: String
    let identifier: String
    let content: Content

    init(
        accent: ThemeColor, badgeFill: ThemeColor, onBadge: ThemeColor, icon: VettIDSymbol, title: String, count: Int,
        countLabel: String, identifier: String, @ViewBuilder content: () -> Content
    ) {
        self.accent = accent
        self.badgeFill = badgeFill
        self.onBadge = onBadge
        self.icon = icon
        self.title = title
        self.count = count
        self.countLabel = countLabel
        self.identifier = identifier
        self.content = content()
    }

    /// Counts above this read "99+".
    static var maxCount: Int { 99 }

    var body: some View {
        HStack(spacing: 0) {
            accent.color.frame(width: 4).accessibilityHidden(true).accessibilityIdentifier("\(identifier)_edge")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Spacing.m) {
                    icon.image
                        .font(.system(size: 20))
                        .foregroundStyle(accent.color)
                        .frame(width: 36, height: 36)
                        .background(accent.color.opacity(0.14), in: VettIDShape.pill)
                        .accessibilityHidden(true)
                    Text(title)
                        .vettIDFont(.titleMedium, weight: .semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("\(identifier)_title")
                    Text(count > Self.maxCount ? "\(Self.maxCount)+" : "\(count)")
                        .vettIDFont(.labelMedium, weight: .bold)
                        .foregroundStyle(onBadge.color)
                        .padding(.horizontal, Spacing.s)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(badgeFill.color, in: VettIDShape.pill)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(countLabel)
                        .accessibilityIdentifier("\(identifier)_count")
                }
                Spacer().frame(height: Spacing.s)
                content
            }
            .padding(Spacing.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.background, in: VettIDShape.card)
        .clipShape(VettIDShape.card)
        .overlay(VettIDShape.card.stroke(accent.color.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, Spacing.s)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

private struct SubHeading: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    var body: some View {
        Text(text)
            .vettIDFont(.labelLarge)
            .foregroundStyle(colors.onSurfaceVariant)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.xs)
    }
}

private struct Muted: View {
    @Environment(\.vettIDColors) private var colors
    let text: String
    let identifier: String

    var body: some View {
        Text(text)
            .vettIDFont(.bodyMedium)
            .foregroundStyle(colors.onSurfaceVariant)
            .padding(.vertical, Spacing.xs)
            .accessibilityIdentifier(identifier)
    }
}

/// A text action of a card ("Manage what you share"), at least a touch target high.
private struct TextAction: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let identifier: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).vettIDFont(.labelLarge).foregroundStyle(colors.primary).frame(minHeight: Spacing.touchTarget)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// A share rule for this connection, one row: its tag in the tag's colour (an older rule may name several, any or all), ask or
/// automatic, its fetch limits and end, how many items it shares now (and waiting), and the other rules covering the same
/// items, named by their tags with the 0.23.0 rule: asking wins (§10.12 Overlapping rules). The row opens the rule editor; the
/// bin deletes it after a confirmation. Mirrors vettid-android `RuleLine`.
private struct RuleLine: View {
    @Environment(\.vettIDColors) private var colors
    let rule: ShareRule
    let overlaps: [ShareRule]
    let names: [String: RuleNames.Name]
    let onOpen: @MainActor (String) -> Void
    let onDelete: @MainActor (ShareRule) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { onOpen(rule.ruleID) } label: { summary }
                .buttonStyle(.plain)
                .accessibilityHint(ConnectStrings.shareRuleOpen)
                .accessibilityIdentifier("sharing_rule_\(rule.ruleID)")
            Button { onDelete(rule) } label: {
                VettIDSymbol.delete.image
                    .foregroundStyle(colors.onSurfaceVariant)
                    .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ConnectStrings.shareRuleDelete)
            .accessibilityIdentifier("sharing_rule_delete_\(rule.ruleID)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sharing_rule_row_\(rule.ruleID)")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChipFlow(spacing: Spacing.xs, lineSpacing: Spacing.xs) { ForEach(rule.tags, id: \.self) { TagChip($0) } }
            if rule.tags.count > 1 {
                Text(SharingCardTexts.match(rule.match))
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .padding(.top, Spacing.xxs)
            }
            Text(SharingCardTexts.mode(rule.mode)).vettIDFont(.bodyMedium, weight: .semibold).padding(.top, Spacing.xxs)
            Text(SharingCardTexts.limits(rule)).vettIDFont(.bodySmall)
            Text(SharingCardTexts.counts(rule)).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
            if let also = SharingCardTexts.overlap(rule, overlaps, names: names) {
                Text(also)
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .accessibilityIdentifier("sharing_rule_also_\(rule.ruleID)")
            }
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.touchTarget, alignment: .leading)
        .padding(.vertical, Spacing.s)
        .contentShape(Rectangle())
    }
}

/// An item of the member's the connection can fetch now, how it was given and what is left of it. Mirrors vettid-android
/// `GivenLine`.
private struct GivenLine: View {
    @Environment(\.vettIDColors) private var colors
    let grant: GrantView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(SharingCardTexts.givenName(grant)).vettIDFont(.bodyLarge)
            Text(SharingCardTexts.givenLine(grant)).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sharing_given_\(grant.grantID)")
    }
}

/// An item the connection shares with the member: read-only, marked as theirs. Mirrors vettid-android `ReceivedLine`.
private struct ReceivedLine: View {
    @Environment(\.vettIDColors) private var colors
    let grant: GrantView
    let name: String?
    let onOpen: @MainActor () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                Text(SharingCardTexts.receivedName(grant)).vettIDFont(.bodyLarge)
                Text(SharingCardTexts.receivedLine(grant, name: name)).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.touchTarget, alignment: .leading)
            .padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(ConnectStrings.shareInOpen)
        .accessibilityIdentifier("sharing_received_\(grant.grantID)")
    }
}
#endif
