import SwiftUI

/// The Notifications bell of the drawer screens' top bar (ANDROID-PLAN 0.1.23): [unread] items as a badge ("99+"
/// above 99, none at 0), gold, or red (the error colour) while an [urgent] item is unread.
public struct NotificationBell: Sendable {
    public let unread: Int
    public let urgent: Bool
    public let onTap: @MainActor @Sendable () -> Void

    public init(unread: Int, urgent: Bool, onTap: @escaping @MainActor @Sendable () -> Void) {
        self.unread = unread
        self.urgent = urgent
        self.onTap = onTap
    }

    /// What a screen reader says for the bell ("Notifications, 3 unread").
    public var accessibilityLabel: String {
        if unread <= 0 { return UIStrings.notifications }
        return urgent ? UIStrings.notificationsUnreadUrgent(unread) : UIStrings.notificationsUnread(unread)
    }
}

/// The bell as an icon button with its badge. Mirrors vettid-android `NotificationBellButton`.
public struct NotificationBellButton: View {
    @Environment(\.vettIDColors) private var colors
    let bell: NotificationBell

    public init(_ bell: NotificationBell) { self.bell = bell }

    public var body: some View {
        IconButton(.notifications, label: bell.accessibilityLabel, action: bell.onTap)
            .overlay(alignment: .topTrailing) {
                if bell.unread > 0 {
                    Text(verbatim: badgeText(bell.unread))
                        .vettIDFont(.labelSmall, weight: .bold)
                        .foregroundStyle(bell.urgent ? colors.onError : colors.onPrimaryContainer)
                        .padding(.horizontal, Spacing.xs)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(bell.urgent ? colors.error : colors.primaryContainer, in: VettIDShape.pill)
                        .offset(y: 4)
                        .accessibilityHidden(true)
                        .accessibilityIdentifier(bell.urgent ? "bell_badge_urgent" : "bell_badge")
                        .allowsHitTesting(false)
                }
            }
            .accessibilityIdentifier("top_bar_bell")
    }
}

/// A 48 pt icon button with an accessibility label (Material's `IconButton`).
public struct IconButton: View {
    @Environment(\.vettIDColors) private var colors
    let symbol: VettIDSymbol
    let label: String
    let tint: ThemeColor?
    let action: @MainActor () -> Void

    public init(_ symbol: VettIDSymbol, label: String, tint: ThemeColor? = nil, action: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        self.label = label
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            symbol.image
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(tint ?? colors.onSurface)
                .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Main top bar (Proton inbox): menu, large start-aligned title, optional search, the Notifications [bell] and the
/// member's avatar tile which opens the account sheet. Mirrors vettid-android `VettIdTopAppBar`.
public struct VettIDTopAppBar<Actions: View>: View {
    let title: String
    let accountName: String
    let accountPhoto: UIImage?
    let searchLabel: String?
    let bell: NotificationBell?
    let onMenu: @MainActor () -> Void
    let onAvatar: @MainActor () -> Void
    let onSearch: (@MainActor () -> Void)?
    let actions: Actions

    public init(
        title: String,
        accountName: String,
        accountPhoto: UIImage? = nil,
        searchLabel: String? = nil,
        bell: NotificationBell? = nil,
        onMenu: @escaping @MainActor () -> Void,
        onAvatar: @escaping @MainActor () -> Void,
        onSearch: (@MainActor () -> Void)? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.accountName = accountName
        self.accountPhoto = accountPhoto
        self.searchLabel = searchLabel
        self.bell = bell
        self.onMenu = onMenu
        self.onAvatar = onAvatar
        self.onSearch = onSearch
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: 0) {
            IconButton(.menu, label: UIStrings.openMenu, action: onMenu).accessibilityIdentifier("top_bar_menu")
            Spacer().frame(width: Spacing.s)
            Text(title)
                .vettIDFont(.titleLarge)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            if let onSearch {
                IconButton(.search, label: searchLabel ?? UIStrings.search, action: onSearch)
                    .accessibilityIdentifier("top_bar_search_open")
            }
            actions
            if let bell { NotificationBellButton(bell) }
            Button(action: onAvatar) {
                InitialTile(accountName, size: 36, style: .ownAccount, photo: accountPhoto)
                    .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                    .contentShape(VettIDShape.tile(Spacing.touchTarget))
            }
            .buttonStyle(.plain)
            .padding(.trailing, Spacing.s)
            .accessibilityLabel(UIStrings.account(accountName))
            .accessibilityIdentifier("top_bar_account")
        }
        .padding(.horizontal, Spacing.xs)
        .frame(minHeight: 72)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// Back-arrow bar for detail and settings screens. The title (if any) goes in the content below: centred for detail
/// screens (``CenteredTitle``), large and start-aligned for settings (``LargeTitle``).
/// Mirrors vettid-android `VettIdBackTopBar`.
public struct VettIDBackTopBar<Actions: View>: View {
    let onBack: @MainActor () -> Void
    let actions: Actions

    public init(onBack: @escaping @MainActor () -> Void, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.onBack = onBack
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: 0) {
            IconButton(.back, label: UIStrings.back, action: onBack).accessibilityIdentifier("top_bar_back")
            Spacer()
            actions
        }
        .padding(.horizontal, Spacing.xs)
        .frame(minHeight: 64)
    }
}

/// A text action at the end of a top bar ("Save item" in the item editor): gold text, a progress ring in its place
/// while [busy] (then not tappable). Mirrors vettid-android `TopBarTextAction`.
public struct TopBarTextAction: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let enabled: Bool
    let busy: Bool
    let action: @MainActor () -> Void

    public init(_ label: String, enabled: Bool = true, busy: Bool = false, action: @escaping @MainActor () -> Void) {
        self.label = label
        self.enabled = enabled
        self.busy = busy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                if busy {
                    ProgressView()
                        .tint(colors.primary.color)
                        .controlSize(.small)
                        .accessibilityIdentifier("top_bar_action_busy")
                }
                Text(label).vettIDFont(.labelLarge, weight: .semibold)
            }
            .foregroundStyle(enabled && !busy ? colors.primary : colors.onSurface.opacity(0.38))
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: Spacing.touchTarget)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
    }
}

/// Centred screen title of a detail screen (Proton message detail). Mirrors vettid-android `CenteredTitle`.
public struct CenteredTitle: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .vettIDFont(.headlineSmall)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.l)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Large start-aligned title (Proton settings). Mirrors vettid-android `LargeTitle`.
public struct LargeTitle: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .vettIDFont(.headlineMedium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Spacing.gutter + Spacing.xs)
            .padding(.trailing, Spacing.gutter)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.l)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A top-level screen's search in its top bar (owner request 2026-10-08): hidden behind a search icon next to the
/// avatar; the icon turns the bar into a focused field; back or ✕ clears the query and brings the bar back. While the
/// query is not empty the field stays shown. Mirrors vettid-android `TopBarSearch`.
public struct TopBarSearchState: Sendable {
    @Binding public var query: String
    @Binding var opened: Bool
    /// The search icon's label ("Search your vault").
    public let label: String
    public let placeholder: String

    public init(query: Binding<String>, opened: Binding<Bool>, label: String, placeholder: String) {
        _query = query
        _opened = opened
        self.label = label
        self.placeholder = placeholder
    }

    /// Whether the bar is the search field.
    public var active: Bool { opened || !query.isEmpty }

    public func open() { opened = true }

    /// Clears the query and shows the normal bar again.
    public func close() {
        query = ""
        opened = false
    }
}

/// The top bar as a search field: back (closes), the field (focused), ✕ (closes). Mirrors vettid-android
/// `SearchTopBar`.
public struct SearchTopBar: View {
    @Environment(\.vettIDColors) private var colors
    @FocusState private var focused: Bool
    let search: TopBarSearchState
    let autoFocus: Bool

    public init(_ search: TopBarSearchState, autoFocus: Bool = true) {
        self.search = search
        self.autoFocus = autoFocus
    }

    public var body: some View {
        HStack(spacing: 0) {
            IconButton(.back, label: UIStrings.closeSearch) { search.close() }
                .accessibilityIdentifier("top_bar_search_back")
            TextField(
                "",
                text: Binding(get: { search.query }, set: { search.query = $0.replacingOccurrences(of: "\n", with: "") }),
                prompt: Text(search.placeholder).foregroundStyle(colors.onSurfaceVariant)
            )
            .vettIDFont(.bodyLarge)
            .submitLabel(.search)
            .focused($focused)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("top_bar_search_field")
            IconButton(.close, label: UIStrings.clearSearch) { search.close() }
                .accessibilityIdentifier("top_bar_search_close")
        }
        .padding(.horizontal, Spacing.xs)
        .frame(minHeight: 72)
        .accessibilityIdentifier("top_bar_search")
        .onAppear { if autoFocus { focused = true } }
    }
}
