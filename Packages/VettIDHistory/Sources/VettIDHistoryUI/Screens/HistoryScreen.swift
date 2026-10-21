#if os(iOS)
import SwiftUI
import VettIDData
import VettIDHistory
import VettIDUI

/// What the History screen can ask for (no-ops by default, for previews and tests). Mirrors vettid-android
/// `HistoryActions`.
public struct HistoryActions {
    public var onOpen: @MainActor (Int64) -> Void = { _ in }
    public var onQuery: @MainActor (String) -> Void = { _ in }
    public var onCategory: @MainActor (AuditCategory?) -> Void = { _ in }
    public var onConnection: @MainActor (String?) -> Void = { _ in }
    public var onDates: @MainActor (DatePreset, Date?, Date?) -> Void = { _, _, _ in }
    public var onClearFilters: @MainActor () -> Void = {}
    public var onLoadMore: @MainActor () -> Void = {}
    public var onRetry: @MainActor () -> Void = {}
    /// The ⋯ menu's "Export…" (ANDROID-PLAN §4 History "Export").
    public var onExport: @MainActor () -> Void = {}

    public init() {}
}

/// History (ANDROID-PLAN §4 History): newest first, more as the list scrolls (`before_seq` cursors), each entry with its
/// title, time and names; a search, the date range, a connection and the groups filter it; the red banner when the
/// unfiltered log does not chain; ⋯ → Export…. Read-only. From the drawer with the top bar ([chrome]); a connection's
/// History with a back arrow ([onBack]). Mirrors vettid-android `HistoryScreen`.
public struct HistoryScreen: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: HistoryState
    let chrome: ShellChrome?
    let onBack: (@MainActor () -> Void)?
    let actions: HistoryActions

    public init(state: HistoryState, chrome: ShellChrome?, onBack: (@MainActor () -> Void)? = nil, actions: HistoryActions) {
        self.state = state
        self.chrome = chrome
        self.onBack = onBack
        self.actions = actions
    }

    public var body: some View {
        Group {
            if let onBack {
                DetailScaffold(onBack: onBack) {
                    VStack(spacing: 0) {
                        LargeTitle(HistoryStrings.title).padding(.horizontal, Spacing.gutter)
                        content
                    }
                } actions: {
                    HistoryMoreMenu(onExport: actions.onExport)
                }
            } else if let chrome {
                TopLevelScaffold(title: HistoryStrings.title, chrome: chrome) {
                    content
                } actions: {
                    HistoryMoreMenu(onExport: actions.onExport)
                }
            }
        }
        .accessibilityIdentifier("history_screen")
    }

    private var content: some View {
        VStack(spacing: 0) {
            if state.chainBroken {
                UrgentBanner(HistoryStrings.chainBroken, actionLabel: HistoryStrings.retry, action: actions.onRetry)
                    .accessibilityIdentifier("history_chain_broken")
            }
            HistorySearchField(query: state.filter.query, onQuery: actions.onQuery)
            HistoryFilterRow(state: state, actions: actions)
            if state.localSearch && state.filter.q != nil {
                Text(HistoryStrings.searchLocal)
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.gutter)
                    .padding(.vertical, Spacing.xs)
                    .accessibilityIdentifier("history_local_search")
            }
            list.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var list: some View {
        if state.loading && state.entries.isEmpty {
            ProgressView().tint(colors.primary.color).accessibilityIdentifier("history_loading")
        } else if let error = state.error, state.entries.isEmpty {
            NoticeCard(.warning, title: error.title(or: HistoryStrings.errorTitle), message: error.message(timeScale: timeScale)) {
                Button(HistoryStrings.retry, action: actions.onRetry).accessibilityIdentifier("history_retry")
            }
            .padding(Spacing.xl)
            .accessibilityIdentifier("history_error")
        } else if state.emptyHistory {
            EmptyState(icon: .history, title: HistoryStrings.emptyTitle, message: HistoryStrings.emptyBody)
                .accessibilityIdentifier("history_empty")
        } else if state.shown.isEmpty && state.end {
            // The one way to clear is "✕ Clear" in the filter row above (owner request 2026-10-09).
            EmptyState(icon: .search, title: HistoryStrings.noMatchTitle, message: HistoryStrings.noMatchBody)
                .accessibilityIdentifier("history_no_match")
        } else {
            HistoryEntryList(state: state, actions: actions)
        }
    }
}

/// History's ⋯ menu: "Export…".
struct HistoryMoreMenu: View {
    let onExport: @MainActor () -> Void

    var body: some View {
        Menu {
            Button(HistoryStrings.exportMenu, action: onExport).accessibilityIdentifier("history_export_open")
        } label: {
            VettIDSymbol.moreHoriz.image.frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
        }
        .accessibilityLabel(HistoryStrings.moreActions)
        .accessibilityIdentifier("history_more")
    }
}

/// The search field (`q` is at most 128 bytes, §10.9: the field stops there). Not a secret: the system keyboard, without
/// autocorrection, so that names are searched as typed.
struct HistorySearchField: View {
    @Environment(\.vettIDColors) private var colors
    let query: String
    let onQuery: @MainActor (String) -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            VettIDSymbol.search.image.foregroundStyle(colors.onSurfaceVariant).accessibilityHidden(true)
            TextField(HistoryStrings.search, text: Binding(get: { query }, set: { new in
                if new.utf8.count <= AuditFilter.maxQBytes { onQuery(new) }
            }))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .vettIDFont(.bodyLarge)
            .accessibilityIdentifier("history_search")
            if !query.isEmpty {
                Button { onQuery("") } label: { VettIDSymbol.close.image.foregroundStyle(colors.onSurfaceVariant) }
                    .accessibilityLabel(HistoryStrings.searchClear)
                    .accessibilityIdentifier("history_search_clear")
            }
        }
        .padding(.horizontal, Spacing.l)
        .frame(minHeight: Spacing.touchTarget)
        .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(colors.outline, lineWidth: 1))
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.xs)
    }
}

/// The entries, newest first; the next page once the last rows come into view; the footer (loading, retry, the start of
/// the history). Mirrors vettid-android `EntryList`.
struct HistoryEntryList: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.colorScheme) private var scheme
    let state: HistoryState
    let actions: HistoryActions
    /// The next page is asked for this many rows before the end.
    static let loadAhead = 5

    var body: some View {
        let shown = state.shown
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.seq) { i, e in
                    let row = state.row(e)
                    VettIDListRow(
                        title: row.title, supporting: row.supporting, meta: e.at.map { HistoryTimes.short($0) },
                        tileName: row.title, tileIcon: HistoryVisuals.symbol(row.category),
                        tileColors: HistoryVisuals.colors(row.category, scheme), onTap: { actions.onOpen(e.seq) }
                    )
                    .accessibilityIdentifier("history_entry_\(e.seq)")
                    .onAppear { if i >= shown.count - Self.loadAhead, !state.end { actions.onLoadMore() } }
                }
                footer.frame(maxWidth: .infinity).padding(Spacing.l)
            }
        }
        .accessibilityIdentifier("history_list")
    }

    @ViewBuilder private var footer: some View {
        if state.loadingMore || (state.loading && !state.entries.isEmpty) {
            VStack(spacing: Spacing.s) {
                ProgressView().tint(colors.primary.color).accessibilityIdentifier("history_loading_more")
                if state.partial || state.filter.q != nil {
                    Text(HistoryStrings.searchingOlder).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(HistoryStrings.loadingMore)
        } else if state.error != nil {
            Button(HistoryStrings.retry, action: actions.onRetry).accessibilityIdentifier("history_retry")
        } else if state.end {
            Text(HistoryStrings.end).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
        } else {
            // Not at the end yet: the footer coming into view asks for more (a list shorter than the screen).
            Color.clear.frame(height: 1).onAppear(perform: actions.onLoadMore)
        }
    }
}
#endif
