import SwiftUI

/// Main view for displaying and voting on proposals
struct ProposalsView: View {
    @StateObject private var viewModel: ProposalsViewModel

    init(authTokenProvider: @escaping @Sendable () -> String?) {
        self._viewModel = StateObject(wrappedValue: ProposalsViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter picker
            filterPicker

            // Content
            contentView
        }
        .navigationTitle("Proposals")
        .task {
            await viewModel.loadProposals()
        }
    }

    // MARK: - Filter Picker

    private var filterPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ProposalFilter.allCases, id: \.self) { filter in
                    ProposalFilterChip(
                        title: filter.rawValue,
                        isSelected: viewModel.selectedFilter == filter
                    ) {
                        viewModel.updateFilter(filter)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.state {
        case .loading:
            loadingView

        case .empty:
            emptyView

        case .loaded:
            proposalsList

        case .error(let message):
            errorView(message)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading proposals...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "doc.text")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Proposals")
                .font(.title2)
                .fontWeight(.semibold)

            Text("There are no proposals available at this time.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    private var proposalsList: some View {
        List(viewModel.filteredProposals) { proposal in
            NavigationLink(destination: ProposalDetailView(
                proposal: proposal,
                viewModel: viewModel
            )) {
                ProposalListRow(
                    proposal: proposal,
                    signatureStatus: viewModel.signatureStatus(for: proposal),
                    hasVoted: viewModel.hasVoted(on: proposal)
                )
            }
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.refresh()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.red)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Proposal Filter Chip

struct ProposalFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : Color(.systemGray5))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Proposal List Row

struct ProposalListRow: View {
    let proposal: Proposal
    let signatureStatus: ProposalSignatureStatus
    let hasVoted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with number and status
            HStack {
                Text(proposal.proposalNumber)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Spacer()

                statusBadge
            }

            // Title
            Text(proposal.proposalTitle)
                .font(.headline)
                .lineLimit(2)

            // Footer with signature and vote status
            HStack {
                signatureIndicator

                Spacer()

                if hasVoted {
                    Label("Voted", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                if proposal.status == .closed && proposal.hasResults {
                    Text("\(proposal.totalVotes) votes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: proposal.status.systemImage)
                .font(.caption2)

            Text(proposal.status.displayName)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.15))
        .foregroundColor(statusColor)
        .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch proposal.status {
        case .open: return .green
        case .closed: return .gray
        case .upcoming: return .blue
        }
    }

    @ViewBuilder
    private var signatureIndicator: some View {
        if signatureStatus.isVerified {
            Label("Verified", systemImage: "checkmark.shield.fill")
                .font(.caption)
                .foregroundColor(.green)
        } else if signatureStatus.error != nil {
            Label("Invalid", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.red)
        } else {
            Label("Verifying...", systemImage: "shield")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ProposalsView(authTokenProvider: { nil })
    }
}
