#if os(iOS)
import SwiftUI
import VettIDConnections
import VettIDData
import VettIDUI

/// What the invite screen can ask for. Mirrors vettid-android `InviteActions`.
public struct InviteActions {
    public var onBack: @MainActor () -> Void = {}
    public var onTtl: @MainActor (InviteTtl) -> Void = { _ in }
    public var onCreate: @MainActor () -> Void = {}
    public var onTick: @MainActor () -> Void = {}
    public var onApprove: @MainActor () -> Void = {}
    public var onDecline: @MainActor () -> Void = {}
    public var onAskBlock: @MainActor (Bool) -> Void = { _ in }
    public var onBlock: @MainActor () -> Void = {}
    public var onCancelInvite: @MainActor () -> Void = {}
    public var onAgain: @MainActor () -> Void = {}
    /// The conversation with the new connection; nil until the messages are in the iPhone app (IOS-PLAN §8 I2.2).
    public var onMessage: (@MainActor (String) -> Void)?

    public init() {}
}

/// Invite a connection (VAULT-MESSAGING §6.4): the lifetime, then the QR code and the link, then the request with its
/// safety code, then the connection. Mirrors vettid-android `InviteScreen`.
public struct InviteScreen: View {
    let state: InviteState
    let actions: InviteActions

    public init(state: InviteState, actions: InviteActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        content
            .confirmDialog(
                isPresented: Binding(get: { state.confirmBlock }, set: { if !$0 { actions.onAskBlock(false) } }),
                title: ConnectStrings.blockRequestTitle,
                message: ConnectStrings.blockRequestBody,
                confirmLabel: ConnectStrings.block,
                destructive: true,
                onConfirm: actions.onBlock
            )
    }

    @ViewBuilder private var content: some View {
        switch state.step {
        case .choose:
            ChooseTtl(state: state, actions: actions)
        case .showing:
            if let invite = state.invite { ShowInvite(invite: invite, state: state, actions: actions) }
        case .request, .connecting:
            if let request = state.request {
                ConnectionRequestContent(
                    request: request, approved: state.step == .connecting, autoApproved: state.autoApproved, busy: state.busy,
                    error: state.error, actions: requestActions
                )
            }
        case .connected:
            ConnectedScreen(
                name: state.connectionName,
                onMessage: opening(actions.onMessage, state.connectionID),
                onDone: actions.onBack
            )
        case .expired:
            FormScaffold(
                title: ConnectStrings.inviteExpiredTitle, message: ConnectStrings.inviteExpiredBody,
                primaryLabel: ConnectStrings.inviteAgain, onPrimary: actions.onAgain, onBack: actions.onBack
            ) { EmptyView() }
            .accessibilityIdentifier("invite_expired")
        case .declined:
            // The other member declined (0.10.5, §6.4).
            FormScaffold(
                title: PeerDeclineText.title(outgoing: false, name: state.declinedName ?? state.request?.name),
                message: ConnectStrings.peerDeclinedBody,
                primaryLabel: ConnectStrings.done, onPrimary: actions.onBack, onBack: actions.onBack
            ) { EmptyView() }
            .accessibilityIdentifier("invite_peer_declined")
        }
    }

    private var requestActions: RequestActions {
        RequestActions(
            onApprove: actions.onApprove, onDecline: actions.onDecline, onBlock: { actions.onAskBlock(true) }, onBack: actions.onBack
        )
    }
}

/// The invitation's lifetime: 10 minutes in person, longer for a link (§6.4), as the relay allows.
struct ChooseTtl: View {
    @Environment(\.vettIDColors) private var colors
    let state: InviteState
    let actions: InviteActions

    var body: some View {
        FormScaffold(
            title: ConnectStrings.inviteTitle, message: ConnectStrings.inviteBody, primaryLabel: ConnectStrings.inviteCreate,
            busy: state.busy, onPrimary: actions.onCreate, onBack: actions.onBack
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(state.ttls, id: \.self) { ttl in row(ttl) }
            }
            if state.ttl.remote {
                NoticeCard(.info, title: ConnectStrings.remoteTitle, message: ConnectStrings.remoteBody).padding(.top, Spacing.l)
            }
            FailureLine(kind: state.error)
        }
        .accessibilityIdentifier("invite_choose")
    }

    private func row(_ ttl: InviteTtl) -> some View {
        let selected = ttl == state.ttl
        return Button { actions.onTtl(ttl) } label: {
            HStack(spacing: Spacing.m) {
                (selected ? VettIDSymbol.radioChecked : VettIDSymbol.radioUnchecked).image
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? colors.primary : colors.onSurfaceVariant)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.label(ttl)).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurface)
                    Text(ttl.remote ? ConnectStrings.ttlRemoteHint : ConnectStrings.ttlInPersonHint)
                        .vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Spacing.touchTarget)
            .padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("ttl_\(ttl.seconds)")
    }

    static func label(_ ttl: InviteTtl) -> String {
        switch ttl {
        case .tenMinutes: ConnectStrings.ttl10m
        case .oneHour: ConnectStrings.ttl1h
        case .oneDay: ConnectStrings.ttl24h
        case .sevenDays: ConnectStrings.ttl7d
        }
    }
}

/// The QR code and the link (both out of captures), the expiry, copy and share, and the wait for the other member.
struct ShowInvite: View {
    @Environment(\.vettIDColors) private var colors
    let invite: InviteInfo
    let state: InviteState
    let actions: InviteActions
    @State private var copied = false

    var body: some View {
        FormScaffold(
            title: invite.remote ? ConnectStrings.showRemoteTitle : ConnectStrings.showTitle,
            message: invite.remote ? ConnectStrings.showRemoteBody : ConnectStrings.showBody,
            primaryLabel: nil,
            busy: state.busy,
            secondaryLabel: ConnectStrings.inviteCancel,
            onPrimary: {},
            onSecondary: actions.onCancelInvite,
            onBack: actions.onBack
        ) {
            CaptureProtected { QrCode(invite.qr, accessibilityLabel: ConnectStrings.qrLabel) }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("invite_qr")
            ExpiryLine(exp: invite.exp).padding(.top, Spacing.m)
            Text(ConnectStrings.linkLabel).vettIDFont(.labelLarge).padding(.top, Spacing.l)
            CaptureProtected {
                Text(verbatim: invite.url)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.m)
                    .background(colors.surfaceContainer, in: VettIDShape.card)
            }
            .padding(.top, Spacing.xs)
            .accessibilityIdentifier("invite_link")
            linkButtons.padding(.top, Spacing.s)
            WaitingRow(text: ConnectStrings.waitingScan, identifier: "waiting_scan").padding(.top, Spacing.xl)
            FailureLine(kind: state.error)
        }
        .accessibilityIdentifier("invite_showing")
        // The screen's clock: past the expiry, the code is no longer shown.
        .task(id: invite.inviteID) {
            while !Task.isCancelled {
                actions.onTick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var linkButtons: some View {
        HStack(spacing: Spacing.s) {
            Button {
                // Local to this iPhone (never on Universal Clipboard), gone when the invitation expires (IOS-PLAN §6.5;
                // chosen; not in the spec).
                SecurePasteboard.copy(invite.url, lifetime: max(invite.exp.timeIntervalSinceNow, SecurePasteboard.defaultLifetime))
                copied = true
            } label: {
                OutlinedLabel(symbol: .contentCopy, text: copied ? ConnectStrings.copied : ConnectStrings.copy)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("invite_copy")
            ShareLink(
                item: ConnectStrings.shareText(invite.url),
                subject: Text(ConnectStrings.shareTitle),
                preview: SharePreview(ConnectStrings.shareTitle)
            ) {
                OutlinedLabel(symbol: .share, text: ConnectStrings.share)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("invite_share")
        }
    }
}

/// "Expires in N min, at <time>", read again every second.
struct ExpiryLine: View {
    @Environment(\.vettIDColors) private var colors
    let exp: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.text(exp: exp, now: context.date))
                .vettIDFont(.bodyMedium)
                .foregroundStyle(colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("invite_expiry")
    }

    /// vettid-android `Times.minutesLeft` (whole minutes, never below 0) and `Times.time` (the short time).
    static func text(exp: Date, now: Date) -> String {
        let minutes = max(0, Int(exp.timeIntervalSince(now) / 60))
        return ConnectStrings.expiresIn(minutes, exp.formatted(date: .omitted, time: .shortened))
    }
}

/// An outlined pill button's label with its icon. Mirrors vettid-android's `OutlinedButton` rows of the invite screen.
struct OutlinedLabel: View {
    @Environment(\.vettIDColors) private var colors
    let symbol: VettIDSymbol
    let text: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            symbol.image.font(.system(size: 16))
            Text(text).vettIDFont(.labelLarge)
        }
        .foregroundStyle(colors.onSurface)
        .frame(maxWidth: .infinity, minHeight: Spacing.touchTarget)
        .overlay(VettIDShape.pill.stroke(colors.outline))
        .contentShape(VettIDShape.pill)
    }
}
#endif
