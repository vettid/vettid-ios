import SwiftUI

/// View for displaying vote results and verification options
struct VoteResultsView: View {
    let proposal: Proposal
    @ObservedObject var viewModel: ProposalsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var publishedVotes: PublishedVoteList?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var verificationResult: VoteVerificationResult?
    @State private var isVerifying = false
    @State private var showDownloadOptions = false

    private var voteReceipt: VoteReceipt? {
        viewModel.getVoteReceipt(for: proposal)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Summary section
                summarySection

                Divider()

                // User's vote verification (if they voted)
                if voteReceipt != nil {
                    verificationSection
                    Divider()
                }

                // Public verification tools
                publicVerificationSection

                // Vote list (truncated)
                if let votes = publishedVotes {
                    voteListSection(votes)
                }
            }
            .padding()
        }
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            await loadResults()
        }
        .sheet(isPresented: $showDownloadOptions) {
            DownloadOptionsSheet(proposal: proposal)
        }
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(proposal.proposalTitle)
                .font(.headline)

            if isLoading {
                HStack {
                    ProgressView()
                    Text("Loading results...")
                        .foregroundColor(.secondary)
                }
            } else if let error = loadError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.red)
                    Text(error)
                        .foregroundColor(.secondary)
                }
            } else {
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
                .padding(.top, 8)

                if let merkleRoot = proposal.merkleRoot {
                    HStack {
                        Text("Merkle Root:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(merkleRoot.prefix(20)) + "...")
                            .font(.caption)
                            .fontWeight(.medium)
                            .monospaced()
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Verification Section

    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your Vote Verification")
                .font(.headline)

            if let receipt = voteReceipt {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Your Vote:")
                        Spacer()
                        Text(receipt.choice.displayName)
                            .fontWeight(.bold)
                            .foregroundColor(choiceColor(receipt.choice))
                    }

                    HStack {
                        Text("Voted:")
                        Spacer()
                        Text(receipt.timestamp.formatted())
                    }
                }
                .font(.subheadline)
            }

            if let result = verificationResult {
                verificationStatusView(result)
            } else if isVerifying {
                HStack {
                    ProgressView()
                    Text("Verifying your vote...")
                        .foregroundColor(.secondary)
                }
            } else {
                Button(action: { Task { await verifyVote() } }) {
                    Label("Verify My Vote", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func verificationStatusView(_ result: VoteVerificationResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            verificationRow(
                label: "Your signature is valid",
                isVerified: result.signatureValid
            )
            verificationRow(
                label: "Your vote appears in the published list",
                isVerified: result.foundInList
            )
            verificationRow(
                label: "Your vote is included in the Merkle tree",
                isVerified: result.includedInMerkle
            )
            verificationRow(
                label: "The Merkle root matches the published root",
                isVerified: result.merkleRootMatches
            )
        }
        .padding()
        .background(result.isFullyVerified ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        .cornerRadius(12)
    }

    private func verificationRow(label: String, isVerified: Bool) -> some View {
        HStack {
            Image(systemName: isVerified ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isVerified ? .green : .red)
            Text(label)
                .font(.subheadline)
        }
    }

    // MARK: - Public Verification Section

    private var publicVerificationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Public Verification")
                .font(.headline)

            Text("Anyone can independently verify the vote results.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button(action: { showDownloadOptions = true }) {
                    Label("Download", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: { Task { await verifyAllSignatures() } }) {
                    Label("Verify All", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Vote List Section

    private func voteListSection(_ votes: PublishedVoteList) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anonymized Vote List")
                .font(.headline)

            Text("Showing first 10 of \(votes.votes.count) votes")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(Array(votes.votes.prefix(10))) { vote in
                VoteListRow(vote: vote)
            }

            if votes.votes.count > 10 {
                Text("+ \(votes.votes.count - 10) more votes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - Actions

    private func loadResults() async {
        isLoading = true
        loadError = nil

        // In a real implementation, this would call the API
        // For now, just simulate a delay
        try? await Task.sleep(nanoseconds: 500_000_000)

        isLoading = false
    }

    private func verifyVote() async {
        guard let receipt = voteReceipt else { return }
        isVerifying = true

        // Simulate verification process
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // In real implementation:
        // 1. Derive voting public key from identity
        // 2. Find vote in published list by voting_public_key
        // 3. Verify Ed25519 signature
        // 4. Request and verify Merkle proof

        // For now, return mock result
        verificationResult = VoteVerificationResult(
            signatureValid: true,
            foundInList: true,
            includedInMerkle: true,
            merkleRootMatches: true
        )

        isVerifying = false
    }

    private func verifyAllSignatures() async {
        // In real implementation, verify all signatures in the vote list
    }

    private func choiceColor(_ choice: VoteChoice) -> Color {
        switch choice {
        case .yes: return .green
        case .no: return .red
        case .abstain: return .gray
        }
    }
}

// MARK: - Vote List Row

struct VoteListRow: View {
    let vote: PublishedVote

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(vote.voteHash.prefix(12)) + "...")
                    .font(.caption)
                    .monospaced()
                Text(String(vote.votingPublicKey.prefix(16)) + "...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospaced()
            }

            Spacer()

            Text(vote.choice.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(choiceColor)

            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private var choiceColor: Color {
        switch vote.choice {
        case .yes: return .green
        case .no: return .red
        case .abstain: return .gray
        }
    }
}

// MARK: - Download Options Sheet

struct DownloadOptionsSheet: View {
    let proposal: Proposal
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Button(action: downloadJSON) {
                    Label("Download Vote List (JSON)", systemImage: "doc.text")
                }

                Button(action: saveToFiles) {
                    Label("Save to Files App", systemImage: "folder")
                }
            }
            .navigationTitle("Download Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func downloadJSON() {
        // In real implementation, fetch and prepare JSON for sharing
        dismiss()
    }

    private func saveToFiles() {
        // In real implementation, save to Files app
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        VoteResultsView(
            proposal: Proposal(
                id: "1",
                proposalNumber: "P0000123",
                proposalTitle: "Budget Allocation 2026",
                proposalText: "Sample proposal text",
                opensAt: Date().addingTimeInterval(-86400 * 7),
                closesAt: Date().addingTimeInterval(-86400),
                category: "Finance",
                quorumType: "majority",
                quorumValue: 50,
                createdAt: Date().addingTimeInterval(-86400 * 14),
                signedPayload: nil,
                orgSignature: nil,
                signingKeyId: nil,
                merkleRoot: "abc123def456...",
                voteListUrl: nil,
                resultsYes: 127,
                resultsNo: 58,
                resultsAbstain: 15
            ),
            viewModel: ProposalsViewModel(authTokenProvider: { nil })
        )
    }
}
