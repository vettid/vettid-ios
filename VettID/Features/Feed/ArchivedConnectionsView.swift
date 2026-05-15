import SwiftUI

// MARK: - Archived Connections View

/// Shows terminal-status connections (declined / revoked / expired) that
/// are filtered out of the live feed by `FeedViewModel.rebuildDisplayItems`.
///
/// Routes here from the `archivedFooterRow` on the main feed. Parity with
/// Android `ArchivedConnectionsScreen` (commit `1c5b1ac`).
struct ArchivedConnectionsView: View {

    @StateObject private var viewModel = ArchivedConnectionsViewModel()

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView("Loading archived connections…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                emptyView
            case .loaded(let cards):
                list(cards)
            case .error(let msg):
                errorView(msg)
            }
        }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            Text("No archived connections")
                .font(.headline)
            Text("Connections you decline or that expire show up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ cards: [ConnectionCardData]) -> some View {
        List {
            ForEach(cards) { card in
                ConnectionCard(card: card)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        #if DEBUG
                        print("[ArchivedConnections] tap → detail \(card.connectionId)")
                        #endif
                    }
            }
        }
        .listStyle(.plain)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task { await viewModel.load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ViewModel

@MainActor
final class ArchivedConnectionsViewModel: ObservableObject {

    enum State {
        case loading
        case empty
        case loaded([ConnectionCardData])
        case error(String)
    }

    @Published var state: State = .loading

    /// The feed's connections client (set by the parent before navigation
    /// for now; once `AppState` exposes one centrally this can switch
    /// over). When nil, we fall back to an empty list.
    var connectionsClient: ConnectionsClient?

    func load() async {
        state = .loading
        guard let client = connectionsClient else {
            state = .empty
            return
        }
        do {
            // `connection.list` doesn't take a multi-status filter, so
            // pull everything and filter locally. Terminal-status set
            // matches the live feed's hidden set.
            let result = try await client.list(status: nil)
            let archived = result.items
                .filter { ConnectionCardData.terminalStatuses.contains($0.status) }
                .map { ConnectionCardData.from(record: $0) }
                .sorted { $0.sortTimestamp > $1.sortTimestamp }
            state = archived.isEmpty ? .empty : .loaded(archived)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
