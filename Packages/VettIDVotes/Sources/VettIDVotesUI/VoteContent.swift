#if os(iOS)
import SwiftUI
import VettIDData
import VettIDUI
import VettIDVotes

/// The vote's content (screens 2 to 7), drawn from ``VoteFacts``: the title, the service, the proposal, the states in words
/// in order, the member's choice, the results, the choices with **Cast your vote**, and the buttons (check, proof, release).
struct VoteContent: View {
    @Environment(\.vettIDColors) private var colors
    let state: VoteScreenState
    let facts: VoteFacts
    let actions: VoteActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                LargeTitle(facts.title)
                serviceLine
                proposal
                notes
                yourChoice
                if let results = facts.results { ResultsView(lines: results) }
                if facts.choosing { choosing }
                buttons
            }
            .padding(.bottom, Spacing.xxl)
        }
        .accessibilityIdentifier("vote_content")
    }

    /// The service, as the connection shows it: its name with the label, and that the name is the service's own.
    private var serviceLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: facts.serviceLine).vettIDFont(.bodyLarge).accessibilityIdentifier("vote_service")
            Text(facts.serviceNote).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
        }
        .padding(.horizontal, Spacing.gutter)
        .accessibilityElement(children: .combine)
    }

    /// The proposal's text and facts (screen 2): the service's words as plain text, in full, captioned "Written by <service>".
    @ViewBuilder private var proposal: some View {
        if let text = facts.proposalText {
            VStack(alignment: .leading, spacing: Spacing.s) {
                // Plain text: no links, no markup. The whole text scrolls with the screen and is never truncated.
                Text(verbatim: text).vettIDFont(.bodyLarge).accessibilityIdentifier("vote_text")
                if let w = facts.writtenBy { Text(verbatim: w).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant) }
                ForEach([facts.quorum, facts.binding].compactMap { $0 }, id: \.self) { line in
                    Text(verbatim: line).vettIDFont(.bodyMedium)
                }
                if let c = facts.closes { Text(verbatim: c).vettIDFont(.bodyMedium).accessibilityIdentifier("vote_closes") }
                if let e = facts.extended { Text(verbatim: e).vettIDFont(.bodyMedium) }
            }
            .padding(.horizontal, Spacing.gutter)
        }
    }

    /// The states in words, in order; a failure that arrives while the screen is open is announced.
    private var notes: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(facts.notes, id: \.self) { n in NoteView(line: n) }
            if let m = facts.windowNotClosed {
                // The lock after the cast failed: the window closes by itself once unused; **Close it now** tries again.
                WindowNotClosedCard(message: m, closing: state.windowClosing, onClose: actions.onCloseWindow)
            }
            if let text = facts.alreadyVoted {
                VStack(alignment: .leading, spacing: 0) {
                    NoteCard(severity: .info, heading: nil, text: text)
                    NoticeAction(
                        label: VoteStrings.voteConfirmBack, identifier: "vote_already_voted_back", action: actions.onDismissAlreadyVoted
                    )
                }
                .accessibilityIdentifier("vote_already_voted")
            }
            if let m = facts.castProblem { CastProblemCard(message: m, onDismiss: actions.onDismissCastProblem) }
            if let p = facts.checkProblem {
                NoticeCard(.warning, title: VoteStrings.voteErrorTitle, message: p, announce: .polite)
            }
            if let m = facts.checkOutcome {
                NoticeCard(.info, title: m.title ?? "", message: m.text, announce: .polite).accessibilityIdentifier("vote_check_outcome")
            }
        }
        .padding(.horizontal, Spacing.gutter)
        .onChange(of: facts.notes.map(\.text)) { old, new in
            // Only what is new is said, and not on opening.
            let added = new.filter { !old.contains($0) }
            if !added.isEmpty { Announcer.announce(added.map(plainText).joined(separator: " "), .polite) }
        }
        .accessibilityIdentifier("vote_notes")
    }

    @ViewBuilder private var yourChoice: some View {
        if let line = facts.yourChoice {
            Text(verbatim: line).vettIDFont(.bodyLarge, weight: .semibold)
                .padding(.horizontal, Spacing.gutter)
                .accessibilityIdentifier("vote_your_choice")
        }
    }

    @ViewBuilder private var choosing: some View {
        if let d = state.detail {
            ChoicesView(detail: d, state: state, onSelect: actions.onSelect)
            // The reason a cast is not offered is written where the button would be (it is among the notes above).
            PrimaryButton(VoteStrings.voteCastButton, action: actions.onCast)
                .disabled(!facts.castEnabled)
                .padding(.horizontal, Spacing.gutter)
                .accessibilityIdentifier("vote_cast")
        }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if facts.checkWithService {
                SecondaryButton(VoteStrings.voteCheckWithService, action: actions.onCheck)
                    .disabled(state.checking).accessibilityIdentifier("vote_check")
            }
            if facts.checkAgain {
                SecondaryButton(VoteStrings.voteCheckAgain, action: actions.onCheck)
                    .disabled(state.checking).accessibilityIdentifier("vote_check_again")
            }
            if facts.saveProof { proofButtons }
        }
        .padding(.horizontal, Spacing.gutter)
    }

    @ViewBuilder private var proofButtons: some View {
        SecondaryButton(VoteStrings.voteSaveProof, action: actions.onSaveProof)
            .disabled(state.proofBusy).accessibilityIdentifier("vote_save_proof")
        if let p = facts.proofProblem { NoticeCard(.warning, title: VoteStrings.voteSaveProof, message: p, announce: .polite) }
        if facts.proofSaved { Text(VoteStrings.voteProofSaved).vettIDFont(.bodyMedium).accessibilityIdentifier("vote_proof_saved") }
        if facts.proofSaveFailed {
            Text(VoteStrings.voteProofFailed).vettIDFont(.bodyMedium).foregroundStyle(colors.error)
                .accessibilityIdentifier("vote_proof_failed")
        }
        if facts.release { SecondaryButton(VoteStrings.voteRelease, action: actions.onRelease).accessibilityIdentifier("vote_release") }
        if facts.released { Text(VoteStrings.voteReleased).vettIDFont(.bodyMedium).accessibilityIdentifier("vote_released") }
    }
}
#endif
