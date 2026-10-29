#if os(iOS)
import SwiftUI
import VettIDConnections
import VettIDData
import VettIDUI

/// What the connection detail screen can ask for. Mirrors vettid-android `DetailActions` for what the iPhone has so far:
/// [onMessage] and [onHistory] stay nil (the action hidden) while the app has no messages or History, and the sharing hooks
/// while it has no sharing; member authentication comes with its row.
public struct DetailActions {
    public var onBack: @MainActor () -> Void = {}
    public var onMessage: (@MainActor () -> Void)?
    /// The connection's History (ANDROID-PLAN §4 History).
    public var onHistory: (@MainActor () -> Void)?
    public var onFavorite: @MainActor () -> Void = {}
    public var onAsk: @MainActor (DetailConfirm?) -> Void = { _ in }
    public var onConfirm: @MainActor () -> Void = {}
    public var onDismissNotice: @MainActor () -> Void = {}
    /// Mutes or unmutes the connection's asks (0.23.0 §10.4.1).
    public var onMuteAsks: @MainActor (Bool) -> Void = { _ in }
    /// Resumes paused asks, or allows declined ones again (`connection.asks.resume`).
    public var onResumeAsks: @MainActor () -> Void = {}
    /// What the connection can see of the member's vault (its sharing screen); nil while the app has no sharing.
    public var onSharing: (@MainActor () -> Void)?
    /// What the connection shares with the member (its "Shared with you" screen).
    public var onSharedWithYou: (@MainActor () -> Void)?
    /// "Add a rule": a new share rule for this connection (§10.12).
    public var onShareItems: (@MainActor () -> Void)?
    /// A share rule of this connection's, to change.
    public var onOpenRule: (@MainActor (String) -> Void)?
    /// "Ask for something": a `grant.request` of this connection (§10.12).
    public var onAskForSomething: (@MainActor () -> Void)?
    /// Asks to delete a share rule (nil: never mind); [onDeleteRule] deletes it once confirmed.
    public var onAskDeleteRule: @MainActor (ShareRule?) -> Void = { _ in }
    public var onDeleteRule: @MainActor () -> Void = {}
    /// Reads the connection again after a failed first read.
    public var onRetry: @MainActor () -> Void = {}

    public init() {}

    /// The page shows the sharing cards only once the app has a sharing screen for every one of their actions (chosen; not in
    /// the spec: vettid-android's hooks always exist).
    var hasSharing: Bool {
        onSharing != nil && onSharedWithYou != nil && onShareItems != nil && onOpenRule != nil && onAskForSomething != nil
    }
}

/// A connection (ANDROID-PLAN §4, 0.1.10): titled "First Last" from the names on the peer's VettID account, the display
/// name secondary; its asks (muted or paused first); the profile shared with you (the names labelled as the account's,
/// never verified; the extras as self-asserted); sharing both ways, "You share with <First>" and "<First> shares with you"
/// (two cards, active connections only); when it connected and was last active; and the vault key fingerprint,
/// the lasting identity check. The safety code belongs to the moment of connecting and is not shown here; nor are the
/// owner's alias and note. The pill holds favourite and remove (confirmed). Mirrors vettid-android
/// `ConnectionDetailScreen`.
public struct ConnectionDetailScreen: View {
    @Environment(\.vettIDColors) private var colors
    let state: ConnectionDetailState
    let actions: DetailActions

    public init(state: ConnectionDetailState, actions: DetailActions) {
        self.state = state
        self.actions = actions
    }

    private var title: String {
        AccountNames.cleaned(state.connection?.displayName) ?? ConnectStrings.nameNotShared
    }

    /// In sentences the name is bidi-isolated (VAULT-MESSAGING §10.8); the heading and the tile take the cleaned name, without the isolation.
    private var isolated: String { AccountNames.isolateOrNull(state.connection?.displayName) ?? ConnectStrings.nameNotShared }

    public var body: some View {
        DetailScaffold(onBack: actions.onBack) {
            if let c = state.connection {
                DetailContent(state: state, connection: c, title: title, actions: actions)
            } else {
                ZStack {
                    if state.loading {
                        ProgressView().tint(colors.primary.color)
                    } else if let error = state.error, !state.gone {
                        // The first read failed (other than an unknown connection, which closes the screen).
                        ConnectionsError(kind: error, actionLabel: ConnectStrings.retry, action: actions.onRetry).padding(Spacing.xl)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } overlay: {
            if let c = state.connection { FloatingPillActionBar(pill(c)) }
        }
        .confirmDialog(
            isPresented: Binding(get: { state.confirm == .remove }, set: { if !$0 { actions.onAsk(nil) } }),
            title: ConnectStrings.removeTitle(isolated),
            message: ConnectStrings.removeBody(isolated),
            confirmLabel: ConnectStrings.remove,
            destructive: true,
            onConfirm: actions.onConfirm
        )
        .confirmDialog(
            isPresented: Binding(get: { state.deleteRule != nil }, set: { if !$0 { actions.onAskDeleteRule(nil) } }),
            title: ConnectStrings.shareRuleDeleteTitle,
            message: AccountNames.isolateOrNull(state.connection?.sharingName).map(ConnectStrings.shareRuleDeleteBody)
                ?? ConnectStrings.shareRuleDeleteUnnamed,
            confirmLabel: ConnectStrings.shareRuleDelete,
            destructive: true,
            onConfirm: actions.onDeleteRule
        )
        .onChange(of: state.gone, initial: true) { _, gone in if gone { actions.onBack() } }
        .accessibilityIdentifier("connection_detail")
    }

    /// Message (once the messages are there), favourite, History, remove.
    func pill(_ c: ConnectionInfo) -> [PillAction] {
        // The connection's own name, as vettid-android's pill (its name from the shown connection).
        let named = AccountNames.isolateOrNull(c.displayName) ?? ConnectStrings.nameNotShared
        var list: [PillAction] = []
        if let onMessage = actions.onMessage, c.state == .active {
            list.append(PillAction(.messages, label: ConnectStrings.detailMessage(named), action: onMessage))
        }
        list.append(PillAction(c.favorite ? .star : .starOutline, label: ConnectionRow.favoriteLabel(named, favorite: c.favorite),
                               action: actions.onFavorite))
        if let onHistory = actions.onHistory { list.append(PillAction(.history, label: ConnectStrings.detailHistory, action: onHistory)) }
        list.append(PillAction(.personRemove, label: ConnectStrings.remove, destructive: true) { actions.onAsk(.remove) })
        return list
    }
}

/// The page under the pill: the header, the notices, the asks, the profile, the sharing cards, about, the fingerprint.
struct DetailContent: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: ConnectionDetailState
    let connection: ConnectionInfo
    let title: String
    let actions: DetailActions

    var body: some View {
        let c = connection
        // A connection's asks (0.23.0 §10.4.1): paused or muted comes first, with the action that ends it.
        let asks = c.state == .active ? AsksView.of(c.asks) : nil
        let asksName = AccountNames.isolateOrNull(c.sharingName)
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                header
                if let error = state.error {
                    ConnectionsError(kind: error, actionLabel: ConnectStrings.ok, action: actions.onDismissNotice)
                        .padding(.horizontal, Spacing.s)
                }
                if let asks, asks.prominent { asksCard(asks, asksName) }
                ProfileCard(connection: c)
                if Self.showsSharing(c, actions) { sharingCards(c) }
                if let asks, !asks.prominent { asksCard(asks, asksName) }
                DetailCard {
                    CardTitle(text: ConnectStrings.detailAbout)
                    if let at = c.createdAt { InfoLine(label: ConnectStrings.detailSince, value: ConnectTimes.full(at)) }
                    if let at = c.lastActiveAt { InfoLine(label: ConnectStrings.detailLastActive, value: ConnectTimes.full(at)) }
                }
                if let f = c.keyFingerprint { FingerprintCard(fingerprint: f) }
            }
            .padding(.bottom, 104)
        }
    }

    /// Whether the page shows the sharing cards: an active connection, with every sharing hook of the host.
    static func showsSharing(_ c: ConnectionInfo, _ actions: DetailActions) -> Bool { c.state == .active && actions.hasSharing }

    /// Two directions, two cards: what goes out of the vault, what comes in (owner request 2026-10-08, as vettid-android).
    @ViewBuilder private func sharingCards(_ c: ConnectionInfo) -> some View {
        OutgoingSharingCard(
            sharing: state.sharing, first: c.sharingName, onShare: { actions.onShareItems?() },
            onOpenRule: { actions.onOpenRule?($0) }, onManage: { actions.onSharing?() },
            onDeleteRule: { actions.onAskDeleteRule($0) }
        )
        IncomingSharingCard(
            sharing: state.sharing, first: c.sharingName, onAsk: { actions.onAskForSomething?() },
            onOpen: { actions.onSharedWithYou?() }
        )
    }

    private func asksCard(_ asks: AsksView, _ name: String?) -> some View {
        AsksCard(view: asks, name: name, busy: state.busy, onMute: actions.onMuteAsks, onResume: actions.onResumeAsks)
    }

    private var header: some View {
        let c = connection
        return VStack(spacing: 0) {
            InitialTile(title, size: 72, style: c.favorite ? .favorite : .connection, photo: ProfilePhotos.decode(c.photo))
            Spacer().frame(height: Spacing.m)
            Text(title)
                .vettIDFont(.headlineSmall)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("detail_name")
            if let display = c.secondaryName {
                Text(display).foregroundStyle(colors.onSurfaceVariant).multilineTextAlignment(.center)
                    .accessibilityIdentifier("detail_display_name")
            }
            Text(ConnectStrings.stateLabel(c.state) ?? ConnectStrings.stateActive)
                .vettIDFont(.labelLarge).foregroundStyle(colors.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.s)
    }
}

/// A card's heading.
struct CardTitle: View {
    let text: String

    var body: some View {
        Text(text).vettIDFont(.titleSmall).accessibilityAddTraits(.isHeader).padding(.bottom, Spacing.s)
    }
}

/// A label and its value on one line.
struct InfoLine: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .center) {
            Text(label).foregroundStyle(colors.onSurfaceVariant).frame(maxWidth: .infinity, alignment: .leading)
            Text(value).multilineTextAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }
}

/// The profile shared with the member (VAULT-MESSAGING §10.8): the names on the peer's account (never verified), then
/// the self-asserted extras (display name, shared items), each labelled so.
struct ProfileCard: View {
    @Environment(\.vettIDColors) private var colors
    let connection: ConnectionInfo

    var body: some View {
        let c = connection
        let profileName = AccountNames.cleaned(c.name)
        let hasName = profileName != nil
        DetailCard {
            CardTitle(text: ConnectStrings.detailProfile)
            if c.accountName == nil && !hasName && c.sharedItems.isEmpty {
                Text(ConnectStrings.detailProfileNone).foregroundStyle(colors.onSurfaceVariant)
            }
            if let account = AccountNames.cleaned(c.accountName) {
                InfoLine(label: ConnectStrings.detailAccountName, value: account)
                note(ConnectStrings.namesNote).padding(.bottom, Spacing.s)
            }
            if hasName || !c.sharedItems.isEmpty {
                if let profileName { InfoLine(label: ConnectStrings.detailProfileName, value: profileName) }
                if !c.sharedItems.isEmpty {
                    Text(ConnectStrings.detailSharedItems).vettIDFont(.labelLarge).padding(.top, Spacing.s)
                    ForEach(c.sharedItems, id: \.itemID) { item in
                        // Empty received text is left out with its label, never shown as a blank (§10.8 step 4).
                        if let n = AccountNames.cleaned(item.name) { Text(n).fontWeight(.semibold).padding(.top, Spacing.xs) }
                        ForEach(Array(item.fields.enumerated()), id: \.offset) { _, f in
                            // A value whose label has nothing to show is shown without it, as in Shared with you.
                            if let value = AccountNames.cleaned(f.value) {
                                if let label = AccountNames.cleaned(f.label) {
                                    InfoLine(label: label, value: value)
                                } else {
                                    Text(value).vettIDFont(.bodyMedium)
                                }
                            }
                        }
                    }
                }
                note(ConnectStrings.selfAsserted).padding(.top, Spacing.s)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile_card")
    }

    private func note(_ text: String) -> some View {
        Text(text).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
    }
}

/// The fingerprint of the peer vault's pinned identity key (VAULT-MESSAGING §10.8): identifies the vault, not a person.
struct FingerprintCard: View {
    @Environment(\.vettIDColors) private var colors
    let fingerprint: String

    var body: some View {
        DetailCard {
            CardTitle(text: ConnectStrings.detailKey)
            Text(fingerprint).font(.system(.body, design: .monospaced)).accessibilityIdentifier("detail_fingerprint")
            Text(ConnectStrings.detailKeyNote).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
                .padding(.top, Spacing.xs)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fingerprint_card")
    }
}
#endif
