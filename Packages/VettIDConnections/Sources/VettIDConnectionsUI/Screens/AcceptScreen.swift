#if os(iOS)
import SwiftUI
import VettIDConnections
import VettIDData
import VettIDUI

/// What the accept screen can ask for. Mirrors vettid-android `AcceptActions`.
public struct AcceptActions {
    public var onBack: @MainActor () -> Void = {}
    public var onInput: @MainActor (String) -> Void = { _ in }
    public var onAccept: @MainActor () -> Void = {}
    public var onScan: @MainActor () -> Void = {}
    public var onApprove: @MainActor () -> Void = {}
    public var onDecline: @MainActor () -> Void = {}
    /// The conversation with the new connection; nil until the messages are in the iPhone app (IOS-PLAN §8 I2.2).
    public var onMessage: (@MainActor (String) -> Void)?
    /// The connection's page; nil until it is in the iPhone app (IOS-PLAN §8 I2.1).
    public var onOpenConnection: (@MainActor (String) -> Void)?

    public init() {}
}

/// Accept an invitation (VAULT-MESSAGING §6.4, 0.10.3): paste (or confirm an opened link), wait for the handshake,
/// compare the safety code with the inviter and approve, then wait for the inviter's approval. Mirrors vettid-android
/// `AcceptScreen`.
public struct AcceptScreen: View {
    @Environment(\.vettIDColors) private var colors
    let state: AcceptState
    let actions: AcceptActions

    public init(state: AcceptState, actions: AcceptActions) {
        self.state = state
        self.actions = actions
    }

    private var who: String {
        (state.name ?? state.connectionName).map(AccountNames.isolate) ?? ConnectStrings.requestThem
    }

    public var body: some View {
        switch state.step {
        case .input, .accepting: input
        case .waiting: waiting
        case .compare, .approved: compare
        case .connected:
            ConnectedScreen(
                name: state.connectionName,
                onMessage: opening(actions.onMessage, state.connectionID),
                onDone: actions.onBack
            )
        case .exists: exists
        case .ended: ended
        }
    }

    private var input: some View {
        FormScaffold(
            title: state.fromLink ? ConnectStrings.openLinkTitle : ConnectStrings.acceptTitle,
            message: state.fromLink ? ConnectStrings.openLinkBody : ConnectStrings.acceptBody,
            primaryLabel: ConnectStrings.acceptConnect,
            primaryEnabled: !state.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            busy: state.step == .accepting,
            secondaryLabel: ConnectStrings.acceptScanInstead,
            onPrimary: actions.onAccept,
            onSecondary: actions.onScan,
            onBack: actions.onBack
        ) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(ConnectStrings.acceptField)
                    .vettIDFont(.labelMedium)
                    .foregroundStyle(state.error == nil ? colors.onSurfaceVariant : colors.error)
                // No AutoFill, suggestions or keyboard learning for the link (IOS-PLAN §6.5, vettid-android
                // `excludeFromAutofill`); one line, which a pasted link fills, and no submit key: "Connect" sends it, as
                // on Android (chosen; not in the spec). Out of captures like the invitation's own link (chosen; not in
                // the spec).
                CaptureProtected {
                    VisibleSecretField(
                        ConnectStrings.acceptField, text: Binding(get: { state.input }, set: { actions.onInput($0) }),
                        placeholder: "", monospaced: true, isError: state.error != nil
                    )
                }
                .accessibilityIdentifier("invite_input")
            }
            FailureLine(kind: state.error)
        }
        .accessibilityIdentifier("accept_input")
    }

    private var waiting: some View {
        FormScaffold(
            title: state.name.map { ConnectStrings.waitingTitle(AccountNames.isolate($0)) } ?? ConnectStrings.waitingTitleUnnamed,
            message: ConnectStrings.waitingBody,
            primaryLabel: ConnectStrings.done,
            busy: state.busy,
            secondaryLabel: ConnectStrings.requestDecline,
            onPrimary: actions.onBack,
            onSecondary: actions.onDecline,
            onBack: actions.onBack
        ) {
            WaitingRow(text: ConnectStrings.waitingHandshake)
            FailureLine(kind: state.error)
        }
        .accessibilityIdentifier("accept_waiting")
    }

    private var compare: some View {
        let approved = state.step == .approved
        return FormScaffold(
            title: approved ? ConnectStrings.approvedTitle : ConnectStrings.compareTitle,
            message: approved
                ? ConnectStrings.approvedBody(who)
                : (state.remote ? ConnectStrings.sasHintInviteeRemote(who) : ConnectStrings.sasHintInvitee(who)),
            primaryLabel: approved ? ConnectStrings.done : ConnectStrings.compareApprove,
            busy: state.busy,
            secondaryLabel: ConnectStrings.requestDecline,
            onPrimary: approved ? actions.onBack : actions.onApprove,
            onSecondary: actions.onDecline,
            onBack: actions.onBack
        ) {
            if let sas = state.sas { LabeledSas(sas: sas) }
            if approved { WaitingRow(text: ConnectStrings.waitingPeer(who)).padding(.top, Spacing.xl) }
            FailureLine(kind: state.error)
        }
        .accessibilityIdentifier(approved ? "accept_approved" : "accept_compare")
    }

    /// "Open the connection" once the connection's page is in the iPhone app; until then "Done" alone (chosen; not in the
    /// spec).
    private var exists: some View {
        let open = opening(actions.onOpenConnection, state.connectionID)
        return FormScaffold(
            title: ConnectStrings.existsTitle,
            message: ConnectStrings.existsBody(who),
            primaryLabel: open == nil ? ConnectStrings.done : ConnectStrings.existsOpen,
            secondaryLabel: open == nil ? nil : ConnectStrings.done,
            onPrimary: open ?? actions.onBack,
            onSecondary: actions.onBack,
            onBack: actions.onBack
        ) { EmptyView() }
        .accessibilityIdentifier("accept_exists")
    }

    /// The inviter declined (0.10.5, §6.4): "<name> declined your connection request"; otherwise why no connection was
    /// made.
    private var ended: some View {
        let peer = state.end == .peerDeclined
        return FormScaffold(
            title: peer ? PeerDeclineText.title(outgoing: true, name: state.name) : ConnectStrings.endedTitle,
            message: Self.endedBody(state.end),
            primaryLabel: ConnectStrings.done,
            onPrimary: actions.onBack,
            onBack: actions.onBack
        ) { EmptyView() }
        .accessibilityIdentifier(peer ? "accept_peer_declined" : "accept_ended")
    }

    static func endedBody(_ end: RequestEnd?) -> String {
        switch end {
        case .peerDeclined: ConnectStrings.peerDeclinedBody
        case .declined: ConnectStrings.endedDeclined
        case .expired: ConnectStrings.endedExpired
        default: ConnectStrings.endedFailed
        }
    }
}
#endif
