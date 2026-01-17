import SwiftUI

/// Detailed view for a single proposal with voting capability
struct ProposalDetailView: View {
    let proposal: Proposal
    @ObservedObject var viewModel: ProposalsViewModel

    @State private var selectedChoice: VoteChoice?
    @State private var showVoteConfirmation = false
    @State private var showPasswordPrompt = false
    @State private var isSubmittingVote = false
    @State private var voteError: String?
    @State private var showResults = false

    private var hasVoted: Bool {
        viewModel.hasVoted(on: proposal)
    }

    private var voteReceipt: VoteReceipt? {
        viewModel.getVoteReceipt(for: proposal)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                proposalHeader

                // Signature verification status
                signatureStatus

                Divider()

                // Proposal text
                proposalContent

                Divider()

                // Voting section or results
                if proposal.status == .open && !hasVoted {
                    votingSection
                } else if hasVoted {
                    votedSection
                } else if proposal.status == .closed && proposal.hasResults {
                    resultsSection
                } else if proposal.status == .upcoming {
                    upcomingSection
                }
            }
            .padding()
        }
        .navigationTitle(proposal.proposalNumber)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Cast Your Vote", isPresented: $showVoteConfirmation) {
            Button("Cancel", role: .cancel) {
                selectedChoice = nil
            }
            Button("Confirm") {
                showPasswordPrompt = true
            }
        } message: {
            if let choice = selectedChoice {
                Text("You are about to vote '\(choice.displayName)' on this proposal. This action cannot be undone.")
            }
        }
        .alert("Error", isPresented: .constant(voteError != nil)) {
            Button("OK") { voteError = nil }
        } message: {
            if let error = voteError {
                Text(error)
            }
        }
        .sheet(isPresented: $showResults) {
            NavigationView {
                VoteResultsView(proposal: proposal, viewModel: viewModel)
            }
        }
    }

    // MARK: - Header

    private var proposalHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                statusBadge

                Spacer()

                if let category = proposal.category {
                    Text(category)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .clipShape(Capsule())
                }
            }

            Text(proposal.proposalTitle)
                .font(.title2)
                .fontWeight(.bold)

            // Dates
            VStack(alignment: .leading, spacing: 4) {
                dateRow(label: "Opens", date: proposal.opensAt)
                dateRow(label: "Closes", date: proposal.closesAt)
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: proposal.status.systemImage)
            Text(proposal.status.displayName)
                .fontWeight(.medium)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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

    private func dateRow(label: String, date: Date) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Text(date.formatted(date: .abbreviated, time: .shortened))
                .fontWeight(.medium)
        }
        .font(.caption)
    }

    // MARK: - Signature Status

    @ViewBuilder
    private var signatureStatus: some View {
        let status = viewModel.signatureStatus(for: proposal)

        HStack(spacing: 8) {
            if status.isVerified {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.green)
                Text("Signature Verified")
                    .fontWeight(.medium)
                    .foregroundColor(.green)
            } else if let error = status.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                VStack(alignment: .leading) {
                    Text("Invalid Signature")
                        .fontWeight(.medium)
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Image(systemName: "shield")
                    .foregroundColor(.secondary)
                Text("Verifying signature...")
                    .foregroundColor(.secondary)
            }
        }
        .font(.subheadline)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Content

    private var proposalContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proposal Details")
                .font(.headline)

            Text(proposal.proposalText)
                .font(.body)
                .foregroundColor(.primary)
        }
    }

    // MARK: - Voting Section

    private var votingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cast Your Vote")
                .font(.headline)

            Text("Select your choice below. Your vote will be signed by your vault and cannot be changed after submission.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                ForEach(VoteChoice.allCases, id: \.self) { choice in
                    VoteOptionButton(
                        choice: choice,
                        isSelected: selectedChoice == choice,
                        isDisabled: isSubmittingVote
                    ) {
                        selectedChoice = choice
                        showVoteConfirmation = true
                    }
                }
            }

            if isSubmittingVote {
                HStack {
                    ProgressView()
                    Text("Submitting vote...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
        }
    }

    // MARK: - Voted Section

    private var votedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)

                VStack(alignment: .leading) {
                    Text("You Have Voted")
                        .font(.headline)
                    if let receipt = voteReceipt {
                        Text("Your vote: \(receipt.choice.displayName)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let receipt = voteReceipt {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vote Receipt")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        receiptRow(label: "Voted", value: receipt.timestamp.formatted())
                        receiptRow(label: "Vote Hash", value: String(receipt.voteHash.prefix(16)) + "...")
                    }
                    .font(.caption)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
            }

            if proposal.status == .closed {
                Button(action: { showResults = true }) {
                    Label("View Results & Verify", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func receiptRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }

    // MARK: - Results Section

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Results")
                .font(.headline)

            VStack(spacing: 12) {
                ResultBar(label: "Yes", count: proposal.resultsYes ?? 0, total: proposal.totalVotes, color: .green)
                ResultBar(label: "No", count: proposal.resultsNo ?? 0, total: proposal.totalVotes, color: .red)
                ResultBar(label: "Abstain", count: proposal.resultsAbstain ?? 0, total: proposal.totalVotes, color: .gray)
            }

            HStack {
                Text("Total Votes:")
                Spacer()
                Text("\(proposal.totalVotes)")
                    .fontWeight(.bold)
            }
            .font(.subheadline)

            Button(action: { showResults = true }) {
                Label("View Detailed Results", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Upcoming Section

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.blue)
                    .font(.title2)

                VStack(alignment: .leading) {
                    Text("Voting Opens Soon")
                        .font(.headline)
                    Text("Voting will open on \(proposal.opensAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Vote Option Button

struct VoteOptionButton: View {
    let choice: VoteChoice
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: choice.systemImage)
                    .font(.title2)

                Text(choice.displayName)
                    .font(.headline)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
            )
        }
        .disabled(isDisabled)
    }

    private var backgroundColor: Color {
        isSelected ? choiceColor.opacity(0.15) : Color(.systemGray6)
    }

    private var foregroundColor: Color {
        isSelected ? choiceColor : .primary
    }

    private var borderColor: Color {
        isSelected ? choiceColor : Color(.systemGray4)
    }

    private var choiceColor: Color {
        switch choice {
        case .yes: return .green
        case .no: return .red
        case .abstain: return .gray
        }
    }
}

// MARK: - Result Bar

struct ResultBar: View {
    let label: String
    let count: Int
    let total: Int
    let color: Color

    private var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(count) / Double(total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text("\(count) (\(Int(percentage * 100))%)")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color(.systemGray5))
                        .frame(height: 8)
                        .cornerRadius(4)

                    Rectangle()
                        .fill(color)
                        .frame(width: geometry.size.width * percentage, height: 8)
                        .cornerRadius(4)
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ProposalDetailView(
            proposal: Proposal(
                id: "1",
                proposalNumber: "P0000123",
                proposalTitle: "Budget Allocation 2026",
                proposalText: "This proposal outlines the budget allocation for the fiscal year 2026. The proposed budget includes allocations for infrastructure, research, and community programs.",
                opensAt: Date().addingTimeInterval(-86400),
                closesAt: Date().addingTimeInterval(86400 * 7),
                category: "Finance",
                quorumType: "majority",
                quorumValue: 50,
                createdAt: Date().addingTimeInterval(-86400 * 2),
                signedPayload: nil,
                orgSignature: nil,
                signingKeyId: nil,
                merkleRoot: nil,
                voteListUrl: nil,
                resultsYes: nil,
                resultsNo: nil,
                resultsAbstain: nil
            ),
            viewModel: ProposalsViewModel(authTokenProvider: { nil })
        )
    }
}
