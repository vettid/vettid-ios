#if os(iOS)
import SwiftUI
import VettIDData
import VettIDUI
import VettIDVotes

/// A note: the table's words for the vault's state. A conflict found after a verified check is plain text under the results
/// line, with no error colour.
struct NoteView: View {
    let line: VoteNoteLine

    var body: some View {
        if line.note == .inResultsConflict {
            // "Your vote is in the published results." (bold) and what else the service showed: no error colour.
            Text(boldMarked(line.text))
                .vettIDFont(.bodyMedium)
                .accessibilityLabel(plainText(line.text))
                .accessibilityIdentifier("vote_note_inResultsConflict")
        } else {
            NoteCard(severity: line.note.severity, heading: line.heading, text: line.text)
                .accessibilityIdentifier("vote_note_\(line.note)")
        }
    }
}

/// A state in words on a card: the icon and colour follow the severity, the words are what says it.
struct NoteCard: View {
    @Environment(\.vettIDColors) private var colors
    let severity: VoteNote.Severity
    let heading: String?
    let text: String

    var body: some View {
        let (accent, icon): (ThemeColor, VettIDSymbol) = switch severity {
        case .error: (colors.error, .reportProblem)
        case .warning: (colors.warning, .warning)
        case .info, .note: (colors.primary, .info)
        }
        HStack(alignment: .top, spacing: Spacing.m) {
            icon.image.font(.system(size: 20)).foregroundStyle(accent).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let heading { Text(heading).vettIDFont(.titleSmall, weight: .semibold) }
                Text(text).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.l)
        .background(colors.surfaceContainer, in: VettIDShape.card)
        .accessibilityElement(children: .combine)
    }
}

/// The choices in the order sent, each with its label as sent (the reserved `abstain` too), as one single-selection group.
struct ChoicesView: View {
    @Environment(\.vettIDColors) private var colors
    let detail: VoteDetail
    let state: VoteScreenState
    let onSelect: @MainActor (String) -> Void

    private var enabled: Bool { state.cast == .none && state.summary.map(VoteRules.castAllowed) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The group below carries the label "Choose one"; the visible heading is not read a second time.
            Text(VoteStrings.voteChoose).vettIDFont(.titleSmall).padding(.bottom, Spacing.xs).accessibilityHidden(true)
            ForEach(detail.choices, id: \.id) { c in
                let selected = state.selected == c.id
                Button { onSelect(c.id) } label: {
                    HStack(spacing: Spacing.m) {
                        (selected ? VettIDSymbol.radioChecked : VettIDSymbol.radioUnchecked).image
                            .foregroundStyle(selected ? colors.primary : colors.onSurfaceVariant)
                            .accessibilityHidden(true)
                        Text(verbatim: AccountNames.isolateOrNull(c.label) ?? c.id).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurface)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: Spacing.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("vote_choice_\(c.id)")
            }
        }
        .padding(.horizontal, Spacing.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(VoteStrings.voteChoose)
        .accessibilityIdentifier("vote_choices")
    }
}

/// The results (screen 5): only from the verified results; before that, no number at all.
struct ResultsView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let title = lines.first { Text(title).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader) }
            ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).vettIDFont(.bodyLarge)
            }
        }
        .padding(.horizontal, Spacing.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vote_results")
    }
}

/// A cast the vault refused or did not answer: said plainly (the plan's words for each code), never silent. The only action
/// is to put it away: the app never offers to send the vote again (the member casts again from the choices, if they may).
struct CastProblemCard: View {
    let message: VoteMessage
    let onDismiss: @MainActor () -> Void

    var body: some View {
        NoticeCard(.warning, title: message.title ?? "", message: message.text, announce: .assertive) {
            NoticeAction(label: VoteStrings.voteConfirmBack, identifier: "vote_cast_problem_back", action: onDismiss)
        }
        .accessibilityIdentifier("vote_cast_problem")
    }
}
#endif
