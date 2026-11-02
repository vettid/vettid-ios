#if os(iOS)
import SwiftUI
import VettIDData
import VettIDUI
import VettIDVotes

/// What the Votes list can ask for. Mirrors vettid-android `VotesScreen`'s callbacks.
public struct VotesActions {
    public var onOpen: @MainActor (VoteKey) -> Void = { _ in }
    public var onOpenConnection: @MainActor (String) -> Void = { _ in }
    public var onRetry: @MainActor () -> Void = {}
    /// The `dropped` notices of these connections were shown (acknowledged to the vault with the next read).
    public var onNoticesShown: @MainActor ([String]) -> Void = { _ in }
    /// **Close it now** on the unlock window notice.
    public var onCloseWindow: @MainActor () -> Void = {}

    public init() {}
}

/// Votes (ANDROID-PLAN 0.1.102 §4 "Votes", screen 1): a section **Open** (open, upcoming, being checked) and a section
/// **Closed**, as the vault orders them; a row is the title (one line), the service's name with its label, a written time
/// and a status chip in words. At the top: the unlock window notice when a cast could not lock it, "Connect again to vote"
/// for a `reconnect` connection, and the vault's notices of votes it did not keep and of services at their cap of
/// problems. Never an empty screen of nothing: with no vote, no connection to connect again and no notice, it says there
/// are no votes. Mirrors vettid-android `VotesScreen`.
public struct VotesScreen: View {
    let state: VotesState
    let chrome: ShellChrome
    let actions: VotesActions

    public init(state: VotesState, chrome: ShellChrome, actions: VotesActions) {
        self.state = state
        self.chrome = chrome
        self.actions = actions
    }

    public var body: some View {
        TopLevelScaffold(title: VoteStrings.votesTitle, chrome: chrome) { VotesContent(state: state, actions: actions) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("votes_screen")
    }
}

/// The votes of one service connection, from its page ("Votes from <name>"): the same list under a back arrow.
public struct ConnectionVotesScreen: View {
    let state: VotesState
    let onBack: @MainActor () -> Void
    let actions: VotesActions

    public init(state: VotesState, onBack: @escaping @MainActor () -> Void, actions: VotesActions) {
        self.state = state
        self.onBack = onBack
        self.actions = actions
    }

    public var body: some View {
        DetailScaffold(onBack: onBack) { VotesContent(state: state, actions: actions) }
            .accessibilityIdentifier("connection_votes_screen")
    }
}

private struct VotesContent: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: VotesState
    let actions: VotesActions

    var body: some View {
        Group {
            if state.loading {
                ProgressView().tint(colors.primary.color).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("votes_loading")
            } else if state.votes.isEmpty, state.reconnect.isEmpty, let error = state.error {
                NoticeCard(.warning, title: VoteStrings.votesErrorTitle, message: error.message(timeScale: timeScale), announce: .polite) {
                    NoticeAction(label: VoteStrings.votesRetry, identifier: "votes_retry", action: actions.onRetry)
                }
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("votes_error")
            } else if state.empty {
                EmptyState(icon: .howToVote, title: VoteStrings.votesEmptyTitle, message: VoteStrings.votesEmptyBody)
                    .accessibilityIdentifier("votes_empty")
            } else {
                list
            }
        }
        // A `dropped` notice shown is acknowledged to the vault once, so that it does not come back.
        .onChange(of: droppedIDs, initial: true) { _, ids in
            if !ids.isEmpty, state.load == .loaded { actions.onNoticesShown(ids) }
        }
    }

    private var droppedIDs: [String] { state.dropped.map(\.connectionID) }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error = state.error {
                    // The list on screen is what was read before; a refresh that failed says so above it.
                    NoticeCard(
                        .warning, title: VoteStrings.votesErrorTitle, message: error.message(timeScale: timeScale), announce: .polite
                    ) {
                        NoticeAction(label: VoteStrings.votesRetry, identifier: "votes_retry", action: actions.onRetry)
                    }
                    .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
                }
                if let w = state.windowNotClosed {
                    WindowNotClosedCard(message: windowMessage(w), closing: state.windowClosing, onClose: actions.onCloseWindow)
                    .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
                }
                ForEach(state.reconnect, id: \.connectionID) { r in
                    ReconnectCard(name: AccountNames.isolate(r.name)) { actions.onOpenConnection(r.connectionID) }
                        .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
                }
                ForEach(state.dropped, id: \.connectionID) { d in
                    NoticeCard(
                        .warning, title: VoteStrings.votesTitle, message: VoteStrings.voteDropped(service(d.connectionID), Int(d.count))
                    )
                        .accessibilityIdentifier("vote_dropped")
                        .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
                }
                ForEach(state.problems, id: \.connectionID) { p in
                    NoticeCard(
                        .urgent, title: VoteStrings.votesTitle, message: VoteStrings.voteProblems(service(p.connectionID), Int(p.count))
                    )
                        .accessibilityIdentifier("vote_problems")
                        .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
                }
                section(VoteStrings.votesSectionOpen, state.open)
                section(VoteStrings.votesSectionClosed, state.closed)
            }
            .padding(.bottom, Spacing.xxl)
        }
        .accessibilityIdentifier("votes")
    }

    private func windowMessage(_ w: WindowNotClosed) -> VoteMessage {
        let failure = state.windowCloseProblem.map { "\n" + $0.kind.message(timeScale: timeScale) } ?? ""
        return VoteMessage(title: VoteStrings.voteWindowNotClosedTitle, text: VoteTexts.windowNotClosed(w) + failure)
    }

    private func service(_ id: String) -> String { AccountNames.isolate(state.services[id] ?? "") }

    @ViewBuilder private func section(_ title: String, _ votes: [VoteSummary]) -> some View {
        if !votes.isEmpty {
            Text(title)
                .vettIDFont(.titleSmall)
                .foregroundStyle(colors.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
                .accessibilityAddTraits(.isHeader)
            ForEach(votes, id: \.key) { v in
                VoteRow(vote: v, serviceName: state.services[v.connectionID] ?? "") { actions.onOpen(v.key) }
            }
        }
    }
}

/// "Connect again to vote" (screen 8): the connection was made before it said it was a service, so it can't take part in
/// votes. The app does not change the connection's kind or call it a service on its own: the card says only what VettID's
/// service list says.
struct ReconnectCard: View {
    let name: String
    let onOpen: @MainActor () -> Void

    var body: some View {
        NoticeCard(.info, title: VoteStrings.voteReconnectTitle, message: VoteStrings.voteReconnectBody(name)) {
            NoticeAction(label: VoteStrings.voteReconnectOpen, identifier: "vote_reconnect_open", action: onOpen)
        }
        .accessibilityIdentifier("vote_reconnect")
    }
}

/// One row: the title, the service with its label, a written time and the chip. Read whole: "Adopt the budget, from the
/// service Example, you voted".
struct VoteRow: View {
    let vote: VoteSummary
    let serviceName: String
    let onOpen: @MainActor () -> Void

    var body: some View {
        let row = VoteRowFacts.of(vote, serviceName: serviceName)
        VettIDListRow(
            title: row.title, supporting: row.supporting, tileName: row.title, tileIcon: .howToVote, onTap: onOpen,
            below: { StatusChip(chip: row.chip, text: row.chipText) }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("vote_\(vote.connectionID)/\(vote.proposalID)")
    }
}

/// A status chip: always its words (never colour alone); the error colour only for a problem.
struct StatusChip: View {
    @Environment(\.vettIDColors) private var colors
    let chip: VoteChip
    let text: String

    var body: some View {
        let problem = chip == .problem
        Text(text)
            .vettIDFont(.labelSmall)
            .foregroundStyle(problem ? colors.error : colors.onSurfaceVariant)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(problem ? colors.error.opacity(0.14) : colors.surfaceContainerHighest, in: VettIDShape.pill)
            .accessibilityIdentifier("vote_chip")
    }
}

/// A notice's text action ("Try again", "Close it now").
struct NoticeAction: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    var identifier = ""
    var destructive = false
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).vettIDFont(.labelLarge, weight: .semibold).foregroundStyle(destructive ? colors.error : colors.primary)
        }
        .buttonStyle(.plain)
        .frame(minHeight: Spacing.touchTarget)
        .accessibilityIdentifier(identifier)
    }
}

/// The lock after a cast failed (owner behaviour 1): the notice names the unlock time and has **Close it now**; it goes only
/// when that went through. Shown on the vote screen and on the list: the repository holds it, not a screen.
struct WindowNotClosedCard: View {
    let message: VoteMessage
    let closing: Bool
    let onClose: @MainActor () -> Void

    var body: some View {
        NoticeCard(.warning, title: message.title ?? "", message: message.text, announce: .polite) {
            NoticeAction(label: VoteStrings.voteWindowCloseNow, identifier: "vote_window_close", action: onClose)
                .disabled(closing)
        }
        .accessibilityIdentifier("vote_window_not_closed")
    }
}
#endif
