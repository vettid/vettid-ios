import SwiftUI
import CryptoKit

/// View for displaying vote results and verification options
struct VoteResultsView: View {
    let proposal: Proposal
    @ObservedObject var viewModel: ProposalsViewModel
    let apiClient: APIClient
    let authTokenProvider: @Sendable () -> String?
    @Environment(\.dismiss) private var dismiss

    @State private var publishedVotes: PublishedVoteList?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var verificationResult: VoteVerificationResult?
    @State private var isVerifying = false
    @State private var showDownloadOptions = false

    init(
        proposal: Proposal,
        viewModel: ProposalsViewModel,
        apiClient: APIClient = APIClient(),
        authTokenProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.proposal = proposal
        self.viewModel = viewModel
        self.apiClient = apiClient
        self.authTokenProvider = authTokenProvider
    }

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

        guard let authToken = authTokenProvider() else {
            loadError = "Not authenticated"
            isLoading = false
            return
        }

        do {
            publishedVotes = try await apiClient.getPublishedVotes(
                proposalId: proposal.id,
                authToken: authToken
            )
            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func verifyVote() async {
        guard let receipt = voteReceipt else { return }
        guard let authToken = authTokenProvider() else {
            verificationResult = VoteVerificationResult(
                signatureValid: false,
                foundInList: false,
                includedInMerkle: false,
                merkleRootMatches: false
            )
            return
        }

        isVerifying = true

        var signatureValid = false
        var foundInList = false
        var includedInMerkle = false
        var merkleRootMatches = false

        do {
            // 1. Load published votes if not already loaded
            if publishedVotes == nil {
                publishedVotes = try await apiClient.getPublishedVotes(
                    proposalId: proposal.id,
                    authToken: authToken
                )
            }

            // 2. Find vote in published list by voting public key
            if let votes = publishedVotes {
                if let publishedVote = votes.votes.first(where: { $0.votingPublicKey == receipt.votingPublicKey }) {
                    foundInList = true

                    // 3. Verify Ed25519 signature
                    signatureValid = verifyEd25519Signature(
                        vote: publishedVote,
                        voteHash: receipt.voteHash
                    )
                }
            }

            // 4. Get and verify Merkle proof
            if foundInList {
                let proofResponse = try await apiClient.getVoteMerkleProof(
                    proposalId: proposal.id,
                    voteHash: receipt.voteHash,
                    authToken: authToken
                )

                includedInMerkle = true

                // Verify Merkle proof
                merkleRootMatches = verifyMerkleProof(
                    voteHash: receipt.voteHash,
                    proof: proofResponse.proof.proof,
                    expectedRoot: proposal.merkleRoot ?? "",
                    index: proofResponse.proof.index
                )
            }

            verificationResult = VoteVerificationResult(
                signatureValid: signatureValid,
                foundInList: foundInList,
                includedInMerkle: includedInMerkle,
                merkleRootMatches: merkleRootMatches
            )

            // Update receipt verification status
            if let result = verificationResult, result.isFullyVerified {
                viewModel.updateVoteVerificationStatus(
                    forProposalId: proposal.id,
                    isVerified: true
                )
            }

        } catch {
            verificationResult = VoteVerificationResult(
                signatureValid: signatureValid,
                foundInList: foundInList,
                includedInMerkle: false,
                merkleRootMatches: false
            )
        }

        isVerifying = false
    }

    /// Verify Ed25519 signature on a published vote
    private func verifyEd25519Signature(vote: PublishedVote, voteHash: String) -> Bool {
        guard let publicKeyData = Data(base64Encoded: vote.votingPublicKey),
              let signatureData = Data(base64Encoded: vote.signature),
              let messageData = voteHash.data(using: .utf8) else {
            return false
        }

        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            return publicKey.isValidSignature(signatureData, for: messageData)
        } catch {
            #if DEBUG
            print("[VoteVerification] Ed25519 verification failed: \(error)")
            #endif
            return false
        }
    }

    /// Verify a Merkle proof for a vote hash
    private func verifyMerkleProof(voteHash: String, proof: [String], expectedRoot: String, index: Int) -> Bool {
        guard !proof.isEmpty else { return voteHash == expectedRoot }

        var currentHash = voteHash
        var currentIndex = index

        for siblingHash in proof {
            // Determine if current hash is on left or right based on index parity
            let combined: String
            if currentIndex % 2 == 0 {
                // Current is left child
                combined = currentHash + siblingHash
            } else {
                // Current is right child
                combined = siblingHash + currentHash
            }

            // Hash the combined string using SHA256
            if let data = combined.data(using: .utf8) {
                let digest = SHA256.hash(data: data)
                currentHash = digest.map { String(format: "%02x", $0) }.joined()
            } else {
                return false
            }

            currentIndex /= 2
        }

        return currentHash == expectedRoot
    }

    private func verifyAllSignatures() async {
        guard let votes = publishedVotes else { return }

        // Verify all Ed25519 signatures in the vote list
        var validCount = 0
        var invalidCount = 0

        for vote in votes.votes {
            let isValid = verifyEd25519Signature(vote: vote, voteHash: vote.voteHash)
            if isValid {
                validCount += 1
            } else {
                invalidCount += 1
            }
        }

        #if DEBUG
        print("[VoteVerification] Verified \(validCount) valid, \(invalidCount) invalid out of \(votes.votes.count) signatures")
        #endif
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
