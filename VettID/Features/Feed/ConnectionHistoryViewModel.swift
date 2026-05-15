import Foundation
import SwiftUI

// MARK: - Connection History ViewModel

/// Backs `ConnectionHistoryView`. Owns the loaded entries, paging cursor,
/// time-range / category filters, and the search-debounce.
///
/// Pagination strategy: on first load + filter changes + range changes,
/// reset the cursor. `loadMore` fires from the list's bottom-of-list
/// sentinel and appends the next page.
@MainActor
final class ConnectionHistoryViewModel: ObservableObject {

    enum State {
        case loading
        case empty(message: String)
        case loaded([AuditEntry])
        case error(String)
    }

    @Published var state: State = .loading
    @Published var range: AuditTimeRange = .all
    @Published var selectedCategories: Set<AuditEventCategory> = []
    @Published private(set) var hasMore: Bool = false

    /// Wire dependency. Set by the parent view's `task` before the first
    /// load. `AppState` owns the canonical `OwnerSpaceClient` post-warm
    /// and exposes it; this VM will pull from there as wiring matures.
    var client: ConnectionAuditClient?

    // Backing data
    private var entries: [AuditEntry] = []
    private var cursor: AuditCursor? = nil
    /// Last query the VM actually fetched against the server (debounced).
    private var liveQuery: String = ""
    private var pendingSearchTask: Task<Void, Never>? = nil
    private static let searchDebounce: UInt64 = 250_000_000   // 250ms

    // MARK: - Load

    func load(connectionId: String) async {
        guard let client = resolveClient() else {
            state = .error("Vault not ready — try reopening the screen after warm-up.")
            return
        }
        state = .loading
        cursor = nil
        entries = []
        do {
            let result = try await runFetch(client: client, connectionId: connectionId, cursor: nil)
            entries = result.entries
            cursor = result.nextCursor
            hasMore = (result.nextCursor != nil)
            republish(emptyMessage: emptyMessageForCurrentFilters())
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func loadMore(connectionId: String) async {
        guard hasMore, let client = resolveClient(), let cursor = cursor else { return }
        do {
            let result = try await runFetch(client: client, connectionId: connectionId, cursor: cursor)
            entries.append(contentsOf: result.entries)
            self.cursor = result.nextCursor
            hasMore = (result.nextCursor != nil)
            republish(emptyMessage: emptyMessageForCurrentFilters())
        } catch {
            // Don't replace the list on a paging error; surface the
            // problem inline via actionError-style handling would be
            // nicer but out of scope for this pass.
            #if DEBUG
            print("[ConnectionHistoryViewModel] loadMore failed: \(error)")
            #endif
        }
    }

    // MARK: - Filters

    func setRange(_ newRange: AuditTimeRange, connectionId: String) {
        guard newRange != range else { return }
        range = newRange
        Task { await load(connectionId: connectionId) }
    }

    func toggleCategory(_ cat: AuditEventCategory, connectionId: String) {
        if selectedCategories.contains(cat) {
            selectedCategories.remove(cat)
        } else {
            selectedCategories.insert(cat)
        }
        Task { await load(connectionId: connectionId) }
    }

    func clearCategoryFilters(connectionId: String) {
        guard !selectedCategories.isEmpty else { return }
        selectedCategories.removeAll()
        Task { await load(connectionId: connectionId) }
    }

    // MARK: - Search (debounced)

    func scheduleSearch(query: String, connectionId: String) {
        pendingSearchTask?.cancel()
        pendingSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.searchDebounce)
            if Task.isCancelled { return }
            await self?.commitSearch(query: query, connectionId: connectionId)
        }
    }

    private func commitSearch(query: String, connectionId: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != liveQuery else { return }
        liveQuery = trimmed
        await load(connectionId: connectionId)
    }

    // MARK: - Row taps

    func handleTap(_ entry: AuditEntry) {
        // Per-event-type routing will land alongside the call / transfer
        // / grant features. For now the navigation hooks are stubbed —
        // ConnectionDetailView (the screen that hosts this list) owns
        // the navigation stack and can plug in real destinations.
        #if DEBUG
        print("[ConnectionHistory] tap \(entry.eventType) entry=\(entry.entryId) refs=\(entry.refs ?? [:])")
        #endif
    }

    // MARK: - Plumbing

    private func runFetch(client: ConnectionAuditClient,
                          connectionId: String,
                          cursor: AuditCursor?) async throws -> AuditListResult {
        let prefixes = selectedCategories.flatMap(\.eventTypePrefixes)
        if !liveQuery.isEmpty {
            return try await client.search(
                connectionId: connectionId,
                query: liveQuery,
                cursor: cursor,
                eventTypePrefixes: prefixes.isEmpty ? nil : prefixes
            )
        }
        return try await client.list(
            connectionId: connectionId,
            cursor: cursor,
            since: range.sinceEpoch,
            until: nil,
            eventTypePrefixes: prefixes.isEmpty ? nil : prefixes
        )
    }

    private func republish(emptyMessage: String) {
        if entries.isEmpty {
            state = .empty(message: emptyMessage)
        } else {
            state = .loaded(entries)
        }
    }

    private func emptyMessageForCurrentFilters() -> String {
        if !liveQuery.isEmpty {
            return "No results for \"\(liveQuery)\"."
        }
        if !selectedCategories.isEmpty {
            return "No history matches the selected filters."
        }
        if range != .all {
            return "No history in this time range."
        }
        return "No history yet — interactions with this connection will appear here."
    }

    /// Resolve the audit client. Prefer the externally-set one; fall back
    /// to AppState's OwnerSpaceClient via a fresh construction so the VM
    /// works even when nobody injected it (post-Phase 0.10 most call
    /// sites should pass one in).
    private func resolveClient() -> ConnectionAuditClient? {
        if let c = client { return c }
        return nil
    }
}
