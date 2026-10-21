#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// What the Vault list can ask for (no-ops by default, for previews and tests). Mirrors vettid-android `ItemsActions`.
public struct ItemsActions {
    public var onOpen: @MainActor (String) -> Void = { _ in }
    public var onAdd: @MainActor () -> Void = {}
    public var onQuery: @MainActor (String) -> Void = { _ in }
    public var onTag: @MainActor (String?) -> Void = { _ in }
    public var onCategory: @MainActor (String?) -> Void = { _ in }
    public var onSensitivity: @MainActor (Sensitivity?) -> Void = { _ in }
    public var onClearFilters: @MainActor () -> Void = {}
    public var onRetry: @MainActor () -> Void = {}
    /// The tags screen (create, rename, delete).
    public var onTags: @MainActor () -> Void = {}

    public init() {}
}

/// The Vault list over its view model, made when the screen first appears. Mirrors vettid-android `itemsDestination`'s
/// list.
public struct ItemsRoute: View {
    @State private var model: ItemsViewModel
    let chrome: ShellChrome
    let host: ItemsHost

    public init(items: any ItemsRepository, ownerChecks: (any OwnerCheckRepository)?, chrome: ShellChrome, host: ItemsHost) {
        _model = State(initialValue: ItemsViewModel(items: items, ownerChecks: ownerChecks))
        self.chrome = chrome
        self.host = host
    }

    public var body: some View {
        var a = ItemsActions()
        a.onOpen = host.onOpenItem
        a.onAdd = host.onAdd
        a.onQuery = { model.setQuery($0) }
        a.onTag = { model.setTag($0) }
        a.onCategory = { model.setCategory($0) }
        a.onSensitivity = { model.setSensitivity($0) }
        a.onClearFilters = { model.clearFilters() }
        a.onRetry = { model.refresh() }
        a.onTags = host.onTags
        return ItemsScreen(state: model.state, chrome: chrome, actions: a)
    }
}

/// The Vault (ANDROID-PLAN §4): the member's items by name, with a search and filters by tag, category and sensitivity;
/// "Add to vault" is the floating button. Values are never in the list (`item.list` carries none). The search is behind
/// the top bar's search icon, open while it holds a query. Mirrors vettid-android `ItemsScreen`.
public struct ItemsScreen: View {
    @Environment(\.vettIDColors) private var colors
    let state: ItemsState
    let chrome: ShellChrome
    let actions: ItemsActions
    @State private var searchOpen = false

    public init(state: ItemsState, chrome: ShellChrome, actions: ItemsActions) {
        self.state = state
        self.chrome = chrome
        self.actions = actions
    }

    private var search: TopBarSearchState {
        TopBarSearchState(
            query: Binding(get: { state.filter.query }, set: { actions.onQuery($0) }),
            opened: $searchOpen,
            label: ItemsStrings.searchOpen,
            placeholder: ItemsStrings.search
        )
    }

    public var body: some View {
        TopLevelScaffold(title: ItemsStrings.title, chrome: chrome, search: state.items.isEmpty ? nil : search) {
            content
        } overlay: {
            BottomFloatingControls {
                EmptyView()
            } trailing: {
                VettIDFab(.add, label: ItemsStrings.add) { actions.onAdd() }.accessibilityIdentifier("items_add")
            }
        }
        .accessibilityIdentifier("items")
    }

    @ViewBuilder private var content: some View {
        if state.loading {
            ProgressView().tint(colors.primary.color).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let e = state.error, state.items.isEmpty {
            NoticeCard(.warning, title: ItemsStrings.errorList, message: ItemsText.failure(e, shownCode: state.errorCode)) {
                Button(ItemsStrings.retry) { actions.onRetry() }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("items_error")
        } else if state.items.isEmpty {
            EmptyState(icon: .vault, title: ItemsStrings.emptyTitle, message: ItemsStrings.emptyBody).accessibilityIdentifier("items_empty")
        } else {
            VStack(spacing: 0) {
                ItemsFilterRow(state: state, actions: actions)
                if state.visible.isEmpty {
                    // The one way to clear is "✕ Clear" in the filter row above.
                    EmptyState(icon: .search, title: ItemsStrings.noMatchTitle, message: ItemsStrings.noMatchBody)
                        .accessibilityIdentifier("items_no_match")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(state.visible, id: \.itemID) { ItemRow(item: $0, onOpen: actions.onOpen) }
                            // Room for the floating button over the last row.
                            Spacer().frame(height: 96)
                        }
                    }
                    .accessibilityIdentifier("items_list")
                }
            }
        }
    }
}

/// One item: its name, its category (and protection when not standard), its date and its tags.
struct ItemRow: View {
    let item: ItemSummary
    let onOpen: @MainActor (String) -> Void

    var body: some View {
        VettIDListRow(
            title: item.name,
            supporting: ItemsText.rowSupporting(item),
            meta: item.updatedAt.map { ItemTimes.short($0) },
            tileIcon: ItemSymbols.category(item.category),
            onTap: { onOpen(item.itemID) }
        ) {
            if !item.tags.isEmpty { TagChipLine(item.tags, label: ItemsText.tagLabel) }
        }
        .accessibilityIdentifier("items_row_\(item.itemID)")
    }
}

/// The filters: each sensitivity, a category, a tag (in its colour), and "Manage tags"; "✕ Clear" while a filter is on.
/// Mirrors vettid-android `FilterRow`.
struct ItemsFilterRow: View {
    @Environment(\.vettIDColors) private var colors
    let state: ItemsState
    let actions: ItemsActions

    var body: some View {
        FilterChipRow(filtering: !state.filter.isEmpty, onClear: actions.onClearFilters) {
            ForEach(Sensitivity.allCases, id: \.self) { s in
                VettIDFilterChip(ItemsText.sensitivity(s), selected: state.filter.sensitivity == s) { actions.onSensitivity(s) }
                    .accessibilityIdentifier("items_filter_\(s.rawValue)")
            }
            Menu {
                Button(ItemsStrings.filterCategoryAny) { actions.onCategory(nil) }
                ForEach(state.categories, id: \.self) { c in
                    Button { actions.onCategory(c) } label: { Label(ItemsText.category(c), systemImage: ItemSymbols.category(c).rawValue) }
                }
            } label: {
                ChoiceChip(
                    label: state.filter.category.map(ItemsText.category) ?? ItemsStrings.filterCategory,
                    selected: state.filter.category != nil
                )
            }
            .accessibilityIdentifier("items_filter_category")
            if !state.tags.isEmpty {
                Menu {
                    Button(ItemsStrings.filterTagAny) { actions.onTag(nil) }
                    ForEach(state.tags, id: \.self) { t in Button(ItemsText.tagLabel(t)) { actions.onTag(t) } }
                } label: {
                    ChoiceChip(label: state.filter.tag.map(ItemsText.tagLabel) ?? ItemsStrings.filterTag, selected: state.filter.tag != nil)
                }
                .accessibilityIdentifier("items_filter_tag")
            }
            Button(ItemsStrings.tagsManage) { actions.onTags() }
                .vettIDFont(.labelLarge)
                .foregroundStyle(colors.primary)
                .frame(minHeight: Spacing.touchTarget)
                .accessibilityIdentifier("items_manage_tags")
        }
        .padding(.vertical, Spacing.xs)
    }
}

/// A filter chip that opens a choice: its value and a chevron.
struct ChoiceChip: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let selected: Bool

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(label).vettIDFont(.labelLarge).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
        }
        .fixedSize()
        .foregroundStyle(selected ? colors.onSecondaryContainer : colors.onSurfaceVariant)
        .padding(.horizontal, Spacing.m + Spacing.xxs)
        .frame(minHeight: 32)
        .background(selected ? colors.secondaryContainer : ThemeColor(0, alpha: 0), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? ThemeColor(0, alpha: 0) : colors.outline, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// "Add to vault" (VAULT-ITEMS §9: one Add screen, template or blank): a blank item, then the recommended templates by
/// category, each with the sensitivity it suggests. [onPick] gets the template id, or nil for a blank item. Mirrors
/// vettid-android `TemplatePickerScreen`.
public struct TemplatePickerScreen: View {
    let onBack: @MainActor () -> Void
    let onPick: @MainActor (String?) -> Void

    public init(onBack: @escaping @MainActor () -> Void, onPick: @escaping @MainActor (String?) -> Void) {
        self.onBack = onBack
        self.onPick = onPick
    }

    public var body: some View {
        let groups = Dictionary(grouping: ItemTemplates.all, by: \.category)
        DetailScaffold(onBack: onBack) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    LargeTitle(ItemsStrings.addTitle)
                    VettIDListRow(
                        title: ItemsStrings.templateBlank, supporting: ItemsStrings.templateBlankNote, tileIcon: .add,
                        onTap: { onPick(nil) }
                    )
                    .accessibilityIdentifier("items_template_blank")
                    ForEach(ItemTemplates.categories.filter { groups[$0.id] != nil }) { c in
                        SettingsSectionHeader(c.label)
                        ForEach(groups[c.id] ?? []) { t in
                            VettIDListRow(
                                title: t.name, supporting: Self.note(t.sensitivity), tileIcon: ItemSymbols.category(c.id),
                                onTap: { onPick(t.id) }
                            )
                            .accessibilityIdentifier("items_template_\(t.id)")
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("items_templates")
    }

    static func note(_ s: Sensitivity) -> String {
        switch s {
        case .data: ItemsStrings.templateNoteData
        case .secret: ItemsStrings.templateNoteSecret
        case .critical: ItemsStrings.templateNoteCritical
        }
    }
}
#endif
