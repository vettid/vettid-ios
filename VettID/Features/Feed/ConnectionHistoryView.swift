import SwiftUI

// MARK: - Connection History View

/// Per-connection audit trail screen.
///
/// Shows every recorded interaction with one peer (messages, calls,
/// transfers, lifecycle events, system rows) in reverse-chrono order.
/// Backed by `ConnectionAuditClient` — server-side pagination,
/// server-side search, time-range filter.
///
/// Parity with Android `ConnectionHistoryScreen`. The fancy
/// per-event-type detail sheets (call detail, transfer detail) are
/// stubbed as tap logs for now; they get wired up alongside the call
/// and transfer features.
struct ConnectionHistoryView: View {

    let connectionId: String
    let peerName: String

    @StateObject private var viewModel = ConnectionHistoryViewModel()
    /// Search query, debounced into the ViewModel via onChange.
    @State private var queryDraft: String = ""
    @State private var showFilterSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            filterChips
            content
        }
        .navigationTitle(peerName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFilterSheet = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            NavigationView { filterSheet }
        }
        .task {
            await viewModel.load(connectionId: connectionId)
        }
        .refreshable {
            await viewModel.load(connectionId: connectionId)
        }
        .onChange(of: queryDraft) { newValue in
            // 250ms debounce so we don't fire a search on every keypress.
            viewModel.scheduleSearch(query: newValue, connectionId: connectionId)
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search history…", text: $queryDraft)
                .textFieldStyle(.plain)
            if !queryDraft.isEmpty {
                Button {
                    queryDraft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - Filter chips (range)

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AuditTimeRange.allCases, id: \.id) { (range: AuditTimeRange) in
                    rangeChip(range)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(Color(.systemBackground))
    }

    private func rangeChip(_ range: AuditTimeRange) -> some View {
        let isSelected = viewModel.range == range
        return Button {
            viewModel.setRange(range, connectionId: connectionId)
        } label: {
            Text(range.title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.systemGray6))
                .foregroundStyle(isSelected ? Color.white : .primary)
                .clipShape(Capsule())
        }
    }

    // MARK: - Filter sheet (event-type prefixes)

    private var filterSheet: some View {
        List {
            Section("Show only") {
                ForEach(AuditEventCategory.allCases, id: \.id) { (cat: AuditEventCategory) in
                    categoryRow(cat)
                }
            }
            Section {
                Button("Clear filters", role: .destructive) {
                    viewModel.clearCategoryFilters(connectionId: connectionId)
                }
                .disabled(viewModel.selectedCategories.isEmpty)
            }
        }
        .navigationTitle("Filter history")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { showFilterSheet = false }
            }
        }
    }

    private func categoryRow(_ cat: AuditEventCategory) -> some View {
        let isSelected = viewModel.selectedCategories.contains(cat)
        return Button {
            viewModel.toggleCategory(cat, connectionId: connectionId)
        } label: {
            HStack {
                Image(systemName: cat.icon).frame(width: 24)
                Text(cat.title)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            VStack { Spacer(); ProgressView(); Spacer() }
        case .empty(let message):
            emptyView(message)
        case .loaded(let entries):
            entriesList(entries)
        case .error(let msg):
            errorView(msg)
        }
    }

    private func emptyView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func entriesList(_ entries: [AuditEntry]) -> some View {
        List {
            ForEach(entries) { entry in
                AuditEntryRow(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.handleTap(entry)
                    }
            }
            if viewModel.hasMore {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .onAppear {
                        Task { await viewModel.loadMore(connectionId: connectionId) }
                    }
            }
        }
        .listStyle(.plain)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task { await viewModel.load(connectionId: connectionId) }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }
}

// MARK: - Audit Entry Row

private struct AuditEntryRow: View {
    let entry: AuditEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: 18))
                .foregroundStyle(tint)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if let dir = entry.direction {
                        Image(systemName: dir == "sent" ? "arrow.up.right" : "arrow.down.left")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    Text(entry.createdAtDate, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let body = entry.body, !body.isEmpty {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var glyph: String {
        let prefix = entry.eventType.split(separator: ".").first.map(String.init) ?? ""
        switch prefix {
        case "message":  return "text.bubble"
        case "call":     return entry.eventType.contains("video") ? "video.fill" : "phone.fill"
        case "transfer": return "bitcoinsign.circle"
        case "system":   return "circle.dotted"
        case "connection": return "person.2"
        case "verify":   return "checkmark.shield"
        case "grant":    return "lock.shield"
        default:         return "circle"
        }
    }

    private var tint: Color {
        let prefix = entry.eventType.split(separator: ".").first.map(String.init) ?? ""
        switch prefix {
        case "message":    return .accentColor
        case "call":       return entry.eventType.contains("missed") ? .red : .green
        case "transfer":   return .orange
        case "system":     return .purple
        case "connection": return .blue
        case "verify":     return .green
        case "grant":      return .orange
        default:           return .secondary
        }
    }
}

// MARK: - Audit Event Categories

/// Coarse-grained filter buckets shown in the filter sheet. Each maps to
/// a set of vault `event_type` prefixes the audit client sends as the
/// `event_types` argument.
enum AuditEventCategory: String, CaseIterable, Identifiable {
    case messages
    case calls
    case transfers
    case verifyIdentity
    case dataGrants
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages:       return "Messages"
        case .calls:          return "Calls"
        case .transfers:      return "Transfers"
        case .verifyIdentity: return "Verify identity"
        case .dataGrants:     return "Data grants"
        case .system:         return "System events"
        }
    }

    var icon: String {
        switch self {
        case .messages:       return "text.bubble"
        case .calls:          return "phone"
        case .transfers:      return "bitcoinsign.circle"
        case .verifyIdentity: return "checkmark.shield"
        case .dataGrants:     return "lock.shield"
        case .system:         return "circle.dotted"
        }
    }

    var eventTypePrefixes: [String] {
        switch self {
        case .messages:       return ["message."]
        case .calls:          return ["call."]
        case .transfers:      return ["transfer."]
        case .verifyIdentity: return ["verify."]
        case .dataGrants:     return ["grant."]
        case .system:         return ["system."]
        }
    }
}
