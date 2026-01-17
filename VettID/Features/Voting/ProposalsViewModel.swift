import Foundation
import CryptoKit

/// State for proposals list
enum ProposalsListState: Equatable {
    case loading
    case empty
    case loaded([Proposal])
    case error(String)

    var proposals: [Proposal] {
        if case .loaded(let proposals) = self {
            return proposals
        }
        return []
    }
}

/// ViewModel for proposals list and voting
@MainActor
final class ProposalsViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: ProposalsListState = .loading
    @Published private(set) var signatureStatuses: [String: ProposalSignatureStatus] = [:]
    @Published var selectedFilter: ProposalFilter = .all
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let authTokenProvider: @Sendable () -> String?
    private let voteReceiptStore: VoteReceiptStore

    // MARK: - Private State

    private var allProposals: [Proposal] = []
    private var orgSigningKey: String?

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        authTokenProvider: @escaping @Sendable () -> String?,
        voteReceiptStore: VoteReceiptStore = .shared
    ) {
        self.apiClient = apiClient
        self.authTokenProvider = authTokenProvider
        self.voteReceiptStore = voteReceiptStore
    }

    // MARK: - Computed Properties

    /// Filtered proposals based on selected filter
    var filteredProposals: [Proposal] {
        switch selectedFilter {
        case .all:
            return allProposals
        case .open:
            return allProposals.filter { $0.status == .open }
        case .closed:
            return allProposals.filter { $0.status == .closed }
        case .upcoming:
            return allProposals.filter { $0.status == .upcoming }
        }
    }

    /// Check if user has voted on a proposal
    func hasVoted(on proposal: Proposal) -> Bool {
        return voteReceiptStore.hasVoted(onProposalId: proposal.id)
    }

    /// Get vote receipt for a proposal
    func getVoteReceipt(for proposal: Proposal) -> VoteReceipt? {
        return voteReceiptStore.retrieve(forProposalId: proposal.id)
    }

    // MARK: - Loading

    /// Load proposals from API
    func loadProposals() async {
        guard let authToken = authTokenProvider() else {
            state = .error("Not authenticated")
            return
        }

        state = .loading

        do {
            // Load org signing key for signature verification
            if orgSigningKey == nil {
                let keyResponse = try await apiClient.getOrgSigningKey()
                orgSigningKey = keyResponse.publicKey
            }

            // Load proposals
            let response = try await apiClient.getProposals(authToken: authToken)
            allProposals = response.proposals.sorted { $0.createdAt > $1.createdAt }

            if allProposals.isEmpty {
                state = .empty
            } else {
                state = .loaded(filteredProposals)
                // Verify signatures in background
                await verifyProposalSignatures()
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Refresh proposals
    func refresh() async {
        await loadProposals()
    }

    /// Update filter and refresh displayed proposals
    func updateFilter(_ filter: ProposalFilter) {
        selectedFilter = filter
        if !allProposals.isEmpty {
            state = .loaded(filteredProposals)
        }
    }

    // MARK: - Signature Verification

    /// Verify VettID signature on a proposal
    func verifySignature(for proposal: Proposal) async -> ProposalSignatureStatus {
        guard let signedPayload = proposal.signedPayload,
              let signature = proposal.orgSignature,
              let publicKeyBase64 = orgSigningKey else {
            return .failed("Missing signature data")
        }

        do {
            // Decode the public key
            guard let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
                return .failed("Invalid public key format")
            }

            // Decode the signature
            guard let signatureData = Data(base64Encoded: signature) else {
                return .failed("Invalid signature format")
            }

            // Get payload data
            guard let payloadData = signedPayload.data(using: .utf8) else {
                return .failed("Invalid payload format")
            }

            // Verify using Ed25519 (or ECDSA if that's what backend uses)
            // Note: Backend uses ECDSA_SHA_256 via KMS, so we need P256 verification
            let publicKey = try P256.Signing.PublicKey(derRepresentation: publicKeyData)
            let ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)

            if publicKey.isValidSignature(ecdsaSignature, for: payloadData) {
                return .verified
            } else {
                return .failed("Signature verification failed")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Verify signatures for all loaded proposals
    private func verifyProposalSignatures() async {
        for proposal in allProposals {
            let status = await verifySignature(for: proposal)
            signatureStatuses[proposal.id] = status
        }
    }

    /// Get signature status for a proposal
    func signatureStatus(for proposal: Proposal) -> ProposalSignatureStatus {
        return signatureStatuses[proposal.id] ?? .unverified
    }

    // MARK: - Error Handling

    func clearError() {
        errorMessage = nil
    }
}

// MARK: - Filter Options

enum ProposalFilter: String, CaseIterable {
    case all = "All"
    case open = "Open"
    case closed = "Closed"
    case upcoming = "Upcoming"
}
