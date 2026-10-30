#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// What the tags screen can ask for (no-ops by default, for previews and tests). Mirrors vettid-android `TagsActions`.
public struct TagsActions {
    public var onBack: @MainActor () -> Void = {}
    public var onRetry: @MainActor () -> Void = {}
    public var onCreate: @MainActor () -> Void = {}
    public var onEdit: @MainActor (TagView) -> Void = { _ in }
    public var onName: @MainActor (String) -> Void = { _ in }
    public var onDescription: @MainActor (String) -> Void = { _ in }
    public var onSave: @MainActor () -> Void = {}
    public var onDelete: @MainActor () -> Void = {}
    public var onConfirmRename: @MainActor () -> Void = {}
    public var onConfirmDelete: @MainActor () -> Void = {}
    public var onDismiss: @MainActor () -> Void = {}
    public var onDismissError: @MainActor () -> Void = {}
    public var onColour: @MainActor (TagView) -> Void = { _ in }
    /// A palette colour picked: its stored `#rrggbb`, and whether the tag shows it already.
    public var onPickColour: @MainActor (String, Bool) -> Void = { _, _ in }

    public init() {}
}

/// The tags (VAULT-MESSAGING §10.8) over their view model, made when the screen first appears (never in `init`, which
/// SwiftUI runs again whenever the shell is redrawn). Mirrors vettid-android `TagsRouteContent`.
public struct TagsRoute: View {
    private let sharing: any SharingRepository
    let onBack: @MainActor () -> Void
    @State private var model: TagsViewModel?

    public init(sharing: any SharingRepository, onBack: @escaping @MainActor () -> Void) {
        self.sharing = sharing
        self.onBack = onBack
    }

    public var body: some View {
        let m = model
        var a = TagsActions()
        a.onBack = onBack
        a.onRetry = { m?.refresh() }
        a.onCreate = { m?.askCreate() }
        a.onEdit = { m?.edit($0) }
        a.onName = { m?.setName($0) }
        a.onDescription = { m?.setDescription($0) }
        a.onSave = { m?.save() }
        a.onDelete = { m?.askDelete() }
        a.onConfirmRename = { m?.confirmRename() }
        a.onConfirmDelete = { m?.confirmDelete() }
        a.onDismiss = { m?.dismiss() }
        a.onDismissError = { m?.dismissError() }
        a.onColour = { m?.askColour($0) }
        a.onPickColour = { m?.pickColour($0, shown: $1) }
        return TagsScreen(state: m?.state ?? TagsState(registry: sharing.tags), actions: a)
            .onAppear { if model == nil { model = TagsViewModel(sharing: sharing) } }
    }
}

/// The tags: each with how many items carry it and how many sharing rules use it; "New tag" is the button. Mirrors
/// vettid-android `TagsScreen`.
public struct TagsScreen: View {
    @Environment(\.vettIDColors) private var colors
    let state: TagsState
    let actions: TagsActions

    public init(state: TagsState, actions: TagsActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        DetailScaffold(onBack: actions.onBack) {
            VStack(alignment: .leading, spacing: 0) {
                LargeTitle(ItemsStrings.tagsTitle).padding(.horizontal, Spacing.gutter)
                if let e = state.error {
                    let message = ItemsText.failure(e, limit: state.limit, shownCode: state.errorCode)
                    NoticeCard(.warning, title: e.title(or: ItemsStrings.errorItem), message: message, announce: .assertive) {
                        Button(ItemsStrings.ok) { actions.onDismissError() }
                    }
                    .padding(.horizontal, Spacing.s)
                    .accessibilityIdentifier("tags_error")
                }
                content
            }
        } overlay: {
            BottomFloatingControls {
                EmptyView()
            } trailing: {
                VettIDFab(.add, label: ItemsStrings.tagsNew) { actions.onCreate() }.accessibilityIdentifier("tags_new")
            }
        }
        .accessibilityIdentifier("tags")
        .modifier(TagDialogs(state: state, actions: actions))
    }

    @ViewBuilder private var content: some View {
        if state.loading && state.registry == nil {
            ProgressView().tint(colors.primary.color).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.tags.isEmpty {
            EmptyState(icon: .label, title: ItemsStrings.tagsEmptyTitle, message: ItemsStrings.tagsEmptyBody)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.tags) { t in TagRow(tag: t, actions: actions) }
                    Spacer().frame(height: 96)
                }
            }
        }
    }
}

/// One tag: its counts and description; the colour button (owner decision 2026-10-09; `@profile`'s says why it is always
/// gold); a tap edits it, except `@profile`.
struct TagRow: View {
    @Environment(\.vettIDColors) private var colors
    let tag: TagView
    let actions: TagsActions

    var body: some View {
        let label = ItemsText.tagLabel(tag.tag)
        VettIDListRow(
            title: label,
            supporting: ItemsText.tagSupporting(tag),
            meta: tag.reserved ? ItemsText.tagCounts(tag) : nil,
            action: RowAction(icon: .palette, label: ItemsStrings.tagsCdColour(label)) { actions.onColour(tag) },
            tileIcon: tag.reserved ? .person : .label,
            tileColors: TagColors.of(tag.tag, dark: colors.isDark, stored: tag.color),
            onTap: tag.reserved ? nil : { actions.onEdit(tag) }
        )
        .accessibilityIdentifier("tag_\(tag.tag)")
    }
}

/// The tags screen's dialogs. One sheet carries the form (new or edit), the rename and delete previews over it (alerts,
/// so that the form stays under them) and the colour picker; why `@profile` has no colour to pick is an alert of its own.
/// (Chosen; not in the spec: Android shows each as a dialog of its own, one after the other; an iPhone presents one sheet
/// at a time.)
struct TagDialogs: ViewModifier {
    @Environment(\.vettIDCovered) private var covered
    let state: TagsState
    let actions: TagsActions

    private var sheetShown: Binding<Bool> {
        Binding(
            get: { state.dialog != nil && state.dialog != .profileColour },
            set: { if !$0 { actions.onDismiss() } }
        )
    }

    private var profileShown: Binding<Bool> {
        Binding(get: { state.dialog == .profileColour }, set: { if !$0 { actions.onDismiss() } })
    }

    // A cover ("This phone can't use your vault", `vettIDCovered`) closes the sheet and the alert at once (IOS-PLAN
    // §4.4 (1)); the app-switcher cover hides them without closing them.
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: uncovered(sheetShown, covered: covered)) { TagSheet(state: state, actions: actions) }
            .alert(ItemsStrings.tagsColourProfileTitle, isPresented: uncovered(profileShown, covered: covered)) {
                Button(ItemsStrings.ok) { actions.onDismiss() }
            } message: {
                Text(ItemsStrings.tagsColourProfile)
            }
            .closesWhenCovered { if state.dialog != nil { actions.onDismiss() } }
    }
}
#endif
