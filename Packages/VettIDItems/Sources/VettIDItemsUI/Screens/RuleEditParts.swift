#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// A card inside the form, whose content is already inset by the form's own gutter.
private extension View {
    func formCard() -> some View { padding(.horizontal, -Spacing.s) }
}

/// "Select the tag to share": one tag per rule; tags another rule of this connection shares open that rule. Mirrors
/// vettid-android `TagsSection`.
struct RuleTagsSection: View {
    @Environment(\.vettIDColors) private var colors
    let state: RuleEditState
    let name: String
    let actions: RuleEditActions

    var body: some View {
        Text(ItemsStrings.ruleTagTitle).vettIDFont(.titleSmall).accessibilityAddTraits(.isHeader)
        Text(ItemsStrings.ruleTagHint(name)).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
        if state.tags.isEmpty && !state.loading {
            Text(ItemsStrings.ruleNoTags).foregroundStyle(colors.onSurfaceVariant)
        }
        ChipFlow(spacing: Spacing.s, lineSpacing: Spacing.s) {
            ForEach(state.freeTags, id: \.self) { t in TagChoice(tag: t, selected: t == state.tag) { actions.onTag(t) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rule_tags")
        let taken = state.taken.filter { state.tags.contains($0.key) }.sorted { $0.key < $1.key }
        if !taken.isEmpty {
            Text(ItemsStrings.ruleTagTakenTitle).vettIDFont(.labelLarge)
            ForEach(taken, id: \.key) { t, ruleID in
                Button { actions.onOpenRule(ruleID) } label: {
                    HStack(spacing: Spacing.m) {
                        TagChip(ItemsText.tagLabel(t), tag: t)
                        Text(ItemsStrings.ruleTagTaken).vettIDFont(.bodyMedium).foregroundStyle(colors.primary)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: Spacing.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ItemsStrings.ruleTagTakenCd(t))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("rule_tag_taken_\(t)")
            }
        }
    }
}

/// A tag to choose: a pill in the tag's own colour; chosen, it gets a gold outline and a check mark (owner request
/// 2026-10-09). A radio choice for accessibility, at least 48 points tall to touch. Mirrors vettid-android `TagChoice`.
struct TagChoice: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTagColors) private var registry
    let tag: String
    let selected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        let c = TagColors.of(tag, dark: colors.isDark, stored: registry[TagColors.normalize(tag)])
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if selected {
                    VettIDSymbol.check.image
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(c.onContainer)
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("rule_tag_check_\(tag)")
                }
                Text(ItemsText.tagLabel(tag)).vettIDFont(.labelLarge).foregroundStyle(c.onContainer)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs + Spacing.xxs)
            .background(c.container, in: VettIDShape.pill)
            .overlay(selected ? VettIDShape.pill.stroke(colors.primary.color, lineWidth: 2) : nil)
            .frame(minHeight: Spacing.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("rule_tag_\(tag)")
    }
}

/// A rule that names several tags (before one tag per rule): what it is, and that it can only be deleted.
struct ReadOnlyRule: View {
    @Environment(\.vettIDColors) private var colors
    let state: RuleEditState

    var body: some View {
        NoticeCard(.info, title: ItemsStrings.ruleMultiTitle, message: ItemsStrings.ruleMultiBody)
            .accessibilityIdentifier("rule_read_only")
        let r = state.rules.first { $0.ruleID == state.draft.ruleID }
        DetailCard {
            ChipFlow { ForEach(state.draft.tags, id: \.self) { TagChip(ItemsText.tagLabel($0), tag: $0) } }
            Spacer().frame(height: Spacing.s)
            Text(state.draft.match == .all ? ItemsStrings.ruleMatchAllShort : ItemsStrings.ruleMatchAnyShort)
                .vettIDFont(.bodySmall)
                .foregroundStyle(colors.onSurfaceVariant)
            Text(ItemsText.ruleMode(state.draft.mode)).vettIDFont(.bodyMedium)
            if let r { Text(ItemsText.ruleLimits(r)).vettIDFont(.bodySmall) }
        }
        .formCard()
    }
}

/// A radio row: a title and a note. Mirrors vettid-android `Choice`.
struct RuleRadio: View {
    @Environment(\.vettIDColors) private var colors
    let title: String
    let note: String?
    let selected: Bool
    let id: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                (selected ? VettIDSymbol.radioChecked : VettIDSymbol.radioUnchecked).image
                    .foregroundStyle(selected ? colors.primary : colors.onSurfaceVariant)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurface)
                    if let note { Text(note).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant) }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Spacing.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier(id)
    }
}

struct RuleModeSection: View {
    let mode: ShareMode
    let onMode: @MainActor (ShareMode) -> Void

    var body: some View {
        Text(ItemsStrings.ruleMode).vettIDFont(.titleSmall).accessibilityAddTraits(.isHeader)
        RuleRadio(title: ItemsStrings.ruleModeAsk, note: ItemsStrings.ruleModeAskNote, selected: mode == .ask, id: "rule_mode_ask") {
            onMode(.ask)
        }
        RuleRadio(title: ItemsStrings.ruleModeAuto, note: ItemsStrings.ruleModeAutoNote, selected: mode == .auto, id: "rule_mode_auto") {
            onMode(.auto)
        }
    }
}

/// §10.12 `uses` (1–10,000, fetches of each item) and, since 0.23.0, `per_hour` (1–3,600) and `per_day` (1–86,400) for a
/// connection rule: the connection's fetches of all the rule's items together; each optional.
struct RuleLimitsSection: View {
    let state: RuleEditState
    let actions: RuleEditActions

    var body: some View {
        Text(ItemsStrings.ruleLimits).vettIDFont(.titleSmall).accessibilityAddTraits(.isHeader)
        NumberField(
            text: state.usesText, onChange: actions.onUses, caption: ItemsStrings.ruleUses, valid: state.usesValid,
            note: ItemsStrings.ruleUsesNote, bad: ItemsStrings.ruleUsesBad, id: "rule_uses"
        )
        NumberField(
            text: state.perHourText, onChange: actions.onPerHour, caption: ItemsStrings.rulePerHour, valid: state.perHourValid,
            note: ItemsStrings.rulePerNote, bad: ItemsStrings.rulePerHourBad, id: "rule_per_hour"
        )
        NumberField(
            text: state.perDayText, onChange: actions.onPerDay, caption: ItemsStrings.rulePerDay, valid: state.perDayValid,
            note: ItemsStrings.rulePerNote, bad: ItemsStrings.rulePerDayBad, id: "rule_per_day"
        )
    }
}

/// A number typed on the number pad (digits only; the view model keeps only those).
struct NumberField: View {
    let text: String
    let onChange: @MainActor (String) -> Void
    let caption: String
    let valid: Bool
    let note: String
    let bad: String
    let id: String

    var body: some View {
        OutlinedInput(caption: caption, supporting: valid ? note : bad, isError: !valid) {
            PlainField(placeholder: nil, text: text, isError: !valid, onChange: onChange)
                .keyboardType(.numberPad)
                .accessibilityLabel(caption)
                .accessibilityIdentifier(id)
        }
    }
}

/// The end: presets, "Custom…" (a date, then a time), and what the draft ends at. Mirrors vettid-android `EndsSection`.
struct RuleEndsSection: View {
    @Environment(\.vettIDColors) private var colors
    let state: RuleEditState
    let onExpiry: @MainActor (RuleExpiry) -> Void

    var body: some View {
        Text(ItemsStrings.ruleExpiry).vettIDFont(.titleSmall).accessibilityAddTraits(.isHeader)
        let choices = (state.expiry == .keep ? [RuleExpiry.keep] : []) + RuleExpiry.presets + [.custom]
        ChipFlow(spacing: Spacing.s, lineSpacing: Spacing.s) {
            ForEach(choices, id: \.identifier) { e in
                VettIDFilterChip(ItemsText.expiryChoice(e, at: state.draft.expiresAt), selected: state.expiry == e) { onExpiry(e) }
                    .accessibilityIdentifier("rule_end_\(e.identifier)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rule_ends")
        Text(state.draft.expiresAt.map { ItemsStrings.ruleEndsAt(ItemsText.fullTime($0)) } ?? ItemsStrings.ruleEndsNever)
            .vettIDFont(.bodySmall)
            .foregroundStyle(colors.onSurfaceVariant)
            .accessibilityIdentifier("rule_ends_at")
        if state.endInvalid {
            Text(ItemsStrings.ruleEndBad)
                .vettIDFont(.bodySmall)
                .foregroundStyle(colors.error)
                .accessibilityIdentifier("rule_end_bad")
        }
    }
}

struct RuleExistingSwitch: View {
    @Environment(\.vettIDColors) private var colors
    let on: Bool
    let onChange: @MainActor (Bool) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(ItemsStrings.ruleExisting).vettIDFont(.bodyLarge)
                Text(ItemsStrings.ruleExistingNote).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
            }
            Spacer(minLength: Spacing.m)
            Toggle("", isOn: Binding(get: { on }, set: { onChange($0) }))
                .labelsHidden()
                .tint(colors.primary.color)
                .accessibilityLabel(ItemsStrings.ruleExisting)
                .accessibilityIdentifier("rule_existing")
        }
        .frame(minHeight: Spacing.touchTarget)
    }
}

/// The connection's other rules covering the same tags or matched items, named by their tags (VAULT-MESSAGING
/// 0.23.0 §10.12), with its rule: asking wins (an item any of them asks about is shared only after the member approves it),
/// one answer counts for all of them, and the strictest fetch limits apply. Mirrors vettid-android `OverlapCard`.
struct RuleOverlapCard: View {
    @Environment(\.vettIDColors) private var colors
    let state: RuleEditState

    var body: some View {
        let matched = state.preview?.matches.map(\.itemID) ?? []
        let names = state.names
        DetailCard {
            Text(ItemsStrings.ruleOverlapTitle).vettIDFont(.titleSmall)
            Spacer().frame(height: Spacing.xs)
            ForEach(state.overlaps) { o in
                VStack(alignment: .leading, spacing: 0) {
                    Text(ItemsText.ruleNamed(o, names: names)).vettIDFont(.bodyMedium, weight: .semibold)
                    Text(ItemsText.overlapLine(o, draftTags: state.draft.tags, matched: matched)).vettIDFont(.bodySmall)
                }
                .padding(.vertical, Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("rule_overlap_\(o.ruleID)")
            }
            Text(ItemsStrings.ruleOverlapNote)
                .vettIDFont(.bodySmall)
                .foregroundStyle(colors.onSurfaceVariant)
                .accessibilityIdentifier("rule_overlap_note")
        }
        .formCard()
        .accessibilityIdentifier("rule_overlaps")
    }
}

/// The dry run (§10.12): how many items the rule matches and which; critical ones are only usable. Since 0.23.0 each item
/// says what saving does to it (`outcome`): shared at once, or asked, and why ("Asks you first because your “medical” rule
/// covers it", `ask_rule_id`); an item whose state does not change says what it is now. Mirrors vettid-android `Preview`.
struct RulePreviewCard: View {
    @Environment(\.vettIDColors) private var colors
    let state: RuleEditState

    var body: some View {
        DetailCard {
            Text(ItemsStrings.rulePreview).vettIDFont(.titleSmall)
            Spacer().frame(height: Spacing.xs)
            if state.previewing {
                ProgressView().tint(colors.primary.color).controlSize(.small)
            } else if let p = state.preview {
                Text(ItemsText.previewTotal(p, mode: state.draft.mode)).accessibilityIdentifier("rule_preview_total")
                if !state.draft.includeExisting && p.total > 0 {
                    Text(ItemsStrings.rulePreviewLater).vettIDFont(.bodySmall)
                }
                let names = state.names
                ForEach(Array(p.matches.enumerated()), id: \.element.itemID) { i, m in
                    if i > 0 { Hairline(color: colors.outlineVariant) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(m.sensitivity == .critical ? ItemsStrings.rulePreviewUsable(m.name) : m.name)
                        if let note = ItemsText.matchNote(m, rules: state.rules, names: names) {
                            Text(note)
                                .vettIDFont(.bodySmall)
                                .foregroundStyle(colors.onSurfaceVariant)
                                .accessibilityIdentifier("rule_match_note_\(m.itemID)")
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("rule_match_\(m.itemID)")
                }
                if p.total > p.matches.count { Text(ItemsStrings.rulePreviewMore(p.total - p.matches.count)) }
            } else {
                Text(ItemsStrings.rulePreviewNone).foregroundStyle(colors.onSurfaceVariant)
            }
        }
        .formCard()
        .accessibilityIdentifier("rule_preview")
    }
}
#endif
