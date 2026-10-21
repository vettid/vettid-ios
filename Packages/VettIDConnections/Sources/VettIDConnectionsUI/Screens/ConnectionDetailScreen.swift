#if os(iOS)
import SwiftUI
import VettIDConnections
import VettIDData
import VettIDUI

/// What the connection detail screen can ask for. Mirrors vettid-android `DetailActions` for what the iPhone has so far:
/// [onMessage] and [onHistory] stay nil (the action hidden) while the app has no messages or History; member
/// authentication and sharing come with their rows.
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
    /// Reads the connection again after a failed first read.
    public var onRetry: @MainActor () -> Void = {}

    public init() {}
}

/// A connection (ANDROID-PLAN §4, 0.1.10): titled "First Last" from the names on the peer's VettID account, the display
/// name secondary; its asks (muted or paused first); the profile shared with you (the names labelled as the account's,
/// never verified; the extras as self-asserted); when it connected and was last active; and the vault key fingerprint,
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
        guard let c = state.connection, !c.displayName.isEmpty else { return ConnectStrings.nameNotShared }
        return c.displayName
    }

    /// In sentences the name is bidi-isolated (VAULT-MESSAGING §10.8); the heading and the tile take it as is.
    private var isolated: String { AccountNames.isolate(title) }

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
        .onChange(of: state.gone, initial: true) { _, gone in if gone { actions.onBack() } }
        .accessibilityIdentifier("connection_detail")
    }

    /// Message (once the messages are there), favourite, History, remove.
    func pill(_ c: ConnectionInfo) -> [PillAction] {
        // The connection's own name, as vettid-android's pill (its name from the shown connection).
        let named = AccountNames.isolate(c.displayName.isEmpty ? ConnectStrings.nameNotShared : c.displayName)
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

/// The page under the pill: the header, the notices, the asks, the profile, about, the fingerprint.
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
        let asksName = c.sharingName.map(AccountNames.isolate)
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                header
                if let error = state.error {
                    ConnectionsError(kind: error, actionLabel: ConnectStrings.ok, action: actions.onDismissNotice)
                        .padding(.horizontal, Spacing.s)
                }
                if let asks, asks.prominent { asksCard(asks, asksName) }
                ProfileCard(connection: c)
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
        let hasName = !c.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        DetailCard {
            CardTitle(text: ConnectStrings.detailProfile)
            if c.accountName == nil && !hasName && c.sharedItems.isEmpty {
                Text(ConnectStrings.detailProfileNone).foregroundStyle(colors.onSurfaceVariant)
            }
            if let account = c.accountName {
                InfoLine(label: ConnectStrings.detailAccountName, value: account)
                note(ConnectStrings.namesNote).padding(.bottom, Spacing.s)
            }
            if hasName || !c.sharedItems.isEmpty {
                if hasName { InfoLine(label: ConnectStrings.detailProfileName, value: c.name) }
                if !c.sharedItems.isEmpty {
                    Text(ConnectStrings.detailSharedItems).vettIDFont(.labelLarge).padding(.top, Spacing.s)
                    ForEach(c.sharedItems, id: \.itemID) { item in
                        Text(item.name).fontWeight(.semibold).padding(.top, Spacing.xs)
                        ForEach(Array(item.fields.enumerated()), id: \.offset) { _, f in InfoLine(label: f.label, value: f.value) }
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
