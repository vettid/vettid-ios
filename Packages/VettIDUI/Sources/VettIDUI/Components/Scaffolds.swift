import SwiftUI

/// What the app shell gives every top-level screen: drawer and account sheet hooks. Mirrors vettid-android
/// `ShellChrome`.
public struct ShellChrome {
    public let accountName: String
    public let accountPhoto: UIImage?
    /// The Notifications bell; nil hides it (the vault held, or no vault).
    public let bell: NotificationBell?
    public let onMenu: @MainActor () -> Void
    public let onAvatar: @MainActor () -> Void

    public init(
        accountName: String,
        accountPhoto: UIImage? = nil,
        bell: NotificationBell? = nil,
        onMenu: @escaping @MainActor () -> Void,
        onAvatar: @escaping @MainActor () -> Void
    ) {
        self.accountName = accountName
        self.accountPhoto = accountPhoto
        self.bell = bell
        self.onMenu = onMenu
        self.onAvatar = onAvatar
    }
}

/// Top-level (drawer) screen: ``VettIDTopAppBar`` over [content], with an [overlay] for ``BottomFloatingControls``.
/// With [search], the bar has a search icon next to the avatar and becomes the search field while it is open.
/// Mirrors vettid-android `TopLevelScaffold`.
public struct TopLevelScaffold<Content: View, Overlay: View, Actions: View>: View {
    @Environment(\.vettIDColors) private var colors
    let title: String
    let chrome: ShellChrome
    let search: TopBarSearchState?
    let onSearch: (@MainActor () -> Void)?
    let content: Content
    let overlay: Overlay
    let actions: Actions

    public init(
        title: String,
        chrome: ShellChrome,
        search: TopBarSearchState? = nil,
        onSearch: (@MainActor () -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder overlay: () -> Overlay = { EmptyView() },
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.chrome = chrome
        self.search = search
        self.onSearch = onSearch
        self.content = content()
        self.overlay = overlay()
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let search, search.active {
                SearchTopBar(search)
            } else {
                VettIDTopAppBar(
                    title: title,
                    accountName: chrome.accountName,
                    accountPhoto: chrome.accountPhoto,
                    searchLabel: search?.label,
                    bell: chrome.bell,
                    onMenu: chrome.onMenu,
                    onAvatar: chrome.onAvatar,
                    onSearch: search.map { s in { @MainActor in s.open() } } ?? onSearch
                ) { actions }
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) { overlay }
        .background(colors.background)
        // A container, as DetailScaffold is: a screen's identifier on the scaffold is the container's own, and every
        // identifier inside (the top bar's buttons, the search field, the rows) keeps its own (UI tests find them).
        .accessibilityElement(children: .contain)
    }
}

/// Secondary screen: back arrow, then [content] (which starts with a ``LargeTitle`` or ``CenteredTitle``), with an
/// [overlay] for ``FloatingPillActionBar``. Mirrors vettid-android `DetailScaffold`.
public struct DetailScaffold<Content: View, Overlay: View, Actions: View>: View {
    @Environment(\.vettIDColors) private var colors
    let background: ThemeColor?
    let onBack: @MainActor () -> Void
    let content: Content
    let overlay: Overlay
    let actions: Actions

    public init(
        background: ThemeColor? = nil,
        onBack: @escaping @MainActor () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder overlay: () -> Overlay = { EmptyView() },
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.background = background
        self.onBack = onBack
        self.content = content()
        self.overlay = overlay()
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 0) {
            VettIDBackTopBar(onBack: onBack) { actions }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .overlay(alignment: .bottom) { overlay }
        .background(background ?? colors.background)
        // A container: a screen's identifier on the scaffold is the container's own, and every identifier inside (the
        // rows, the buttons, the notices) keeps its own (UI tests find them).
        .accessibilityElement(children: .contain)
    }
}
