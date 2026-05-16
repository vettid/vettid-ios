import SwiftUI

// MARK: - Peer Catalog View

/// Inbound-side companion to MySharingView (Phase 3.10, parity with
/// Android `PeerCatalogScreen`).
///
/// Shows the peer's published `data_catalog` + `secret_catalog` (the
/// fields we already render inline on `BusinessCardView`'s peer card,
/// but in a focused full-screen surface with per-row request status).
/// Tapping a row opens `RequestAccessSheet` — the same sheet the
/// catalog rows on the business card use — so the request flow is
/// uniform regardless of entry point.
///
/// USE_ONLY items get an "Ask to use" label instead of "Request",
/// reflecting that approval triggers a `critical-secret-use.request-use`
/// rather than a value grant.
struct PeerCatalogView: View {

    let peer: MySharingView.Peer
    /// Combined catalog rows the parent supplies — the
    /// ConnectionDetailView already has the peer's BusinessCardData
    /// in hand and can pass through `dataCatalog + secretsCatalog`.
    let entries: [PeerCatalogEntry]

    @StateObject private var viewModel = PeerCatalogViewModel()
    @State private var requestingEntry: PeerCatalogEntry?

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyView
            } else {
                List {
                    Section {
                        ForEach(viewModel.sortedEntries(entries)) { entry in
                            PeerCatalogRow(
                                entry: entry,
                                status: viewModel.status(for: entry.id)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                requestingEntry = entry
                            }
                        }
                    } header: {
                        Text(peer.label.isEmpty ? "Catalog" : "\(peer.label)'s catalog")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("What's available")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.refreshStatuses(for: peer.connectionId)
        }
        .sheet(item: $requestingEntry) { entry in
            NavigationView {
                RequestAccessSheet(
                    peer: .init(connectionId: peer.connectionId, label: peer.label),
                    entry: entry
                )
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Nothing published")
                .font(.headline)
            Text("\(peer.label.isEmpty ? "This connection" : peer.label) hasn't published anything for connections to request yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }
}

// MARK: - Row

private struct PeerCatalogRow: View {
    let entry: PeerCatalogEntry
    let status: SharedItemStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.icon ?? glyphForVisibility(entry.visibility))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                if let alias = entry.alias, !alias.isEmpty {
                    Text("\(entry.label) — \(alias)").font(.subheadline)
                } else {
                    Text(entry.label).font(.subheadline)
                }
                HStack(spacing: 6) {
                    Text(visibilityLabel(entry.visibility))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    statusChip
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusChip: some View {
        if status != .available {
            Text(status.displayLabel)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(statusColor.opacity(0.15))
                .foregroundStyle(statusColor)
                .cornerRadius(4)
        }
    }

    private var statusColor: Color {
        switch status {
        case .pending:   return .orange
        case .approved:  return .green
        case .denied:    return .red
        case .expired:   return .secondary
        case .available: return .secondary
        }
    }

    private func glyphForVisibility(_ wire: String) -> String {
        switch wire.uppercased() {
        case "PROFILE":  return "eye.fill"
        case "CATALOG":  return "doc.text"
        case "USE_ONLY": return "wand.and.stars"
        default:          return "circle"
        }
    }

    private func visibilityLabel(_ wire: String) -> String {
        switch wire.uppercased() {
        case "PROFILE":  return "Shown publicly"
        case "CATALOG":  return "Available to request"
        case "USE_ONLY": return "Available for operations"
        default:          return wire.capitalized
        }
    }
}

// MARK: - View Model

@MainActor
final class PeerCatalogViewModel: ObservableObject {

    /// Per-entry status, keyed by the catalog entry id. Sourced from
    /// the outbound-grants list filtered to this peer — a pending
    /// request for an item key flips the row from "Available" to
    /// "Requested"; an approved grant flips it to "Approved".
    @Published private(set) var statuses: [String: SharedItemStatus] = [:]

    private let grantsRepository: GrantsRepository

    init(grantsRepository: GrantsRepository = .shared) {
        self.grantsRepository = grantsRepository
    }

    func status(for entryId: String) -> SharedItemStatus {
        statuses[entryId] ?? .available
    }

    /// Sort: pending first (call to action), then approved, then
    /// untouched, then denied/expired at the bottom.
    func sortedEntries(_ entries: [PeerCatalogEntry]) -> [PeerCatalogEntry] {
        entries.sorted { a, b in
            let aOrder = sortKey(status(for: a.id))
            let bOrder = sortKey(status(for: b.id))
            if aOrder != bOrder { return aOrder < bOrder }
            return a.label < b.label
        }
    }

    private func sortKey(_ status: SharedItemStatus) -> Int {
        switch status {
        case .pending:   return 0
        case .approved:  return 1
        case .available: return 2
        case .denied:    return 3
        case .expired:   return 4
        }
    }

    /// Pull the latest outbound-grants snapshot from the repository
    /// and project per-entry statuses. Called on .task; the repo
    /// re-hydrates on every grant event (Phase 3.9) so consumers can
    /// react with a fresh refresh().
    func refreshStatuses(for connectionId: String) async {
        var out: [String: SharedItemStatus] = [:]
        for grant in grantsRepository.outbound where grant.connectionId == connectionId {
            // Map status string to enum; the repo stores it raw.
            let s: SharedItemStatus
            switch grant.status.lowercased() {
            case "active":    s = .approved
            case "expired":   s = .expired
            case "revoked":   s = .denied
            case "exhausted": s = .expired
            default:           s = .available
            }
            out[grant.itemRef] = s
        }
        for pending in grantsRepository.pending where pending.connectionId == connectionId {
            // A pending row outranks an approved/expired one for the
            // same item — the user just re-requested.
            out[pending.itemRef] = .pending
        }
        statuses = out
    }
}
