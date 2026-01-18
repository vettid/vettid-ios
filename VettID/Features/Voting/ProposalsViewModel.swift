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

/// State for vote casting
enum VoteCastingState: Equatable {
    case idle
    case sendingToVault
    case waitingForSignature
    case submittingToBackend
    case complete
    case error(String)
}

/// ViewModel for proposals list and voting
@MainActor
final class ProposalsViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: ProposalsListState = .loading
    @Published private(set) var signatureStatuses: [String: ProposalSignatureStatus] = [:]
    @Published private(set) var voteCastingState: VoteCastingState = .idle
    @Published var selectedFilter: ProposalFilter = .all
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let authTokenProvider: @Sendable () -> String?
    private let voteReceiptStore: VoteReceiptStore
    private let natsManager: NatsConnectionManager?
    private let ownerSpaceProvider: () -> String?

    // MARK: - Private State

    private var allProposals: [Proposal] = []
    private var orgSigningKey: String?

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        authTokenProvider: @escaping @Sendable () -> String?,
        voteReceiptStore: VoteReceiptStore = .shared,
        natsManager: NatsConnectionManager? = nil,
        ownerSpaceProvider: @escaping () -> String? = { nil }
    ) {
        self.apiClient = apiClient
        self.authTokenProvider = authTokenProvider
        self.voteReceiptStore = voteReceiptStore
        self.natsManager = natsManager
        self.ownerSpaceProvider = ownerSpaceProvider
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

    /// Update verification status for a vote receipt
    func updateVoteVerificationStatus(forProposalId proposalId: String, isVerified: Bool) {
        try? voteReceiptStore.updateVerificationStatus(forProposalId: proposalId, isVerified: isVerified)
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

    // MARK: - Vote Casting

    /// Cast a vote on a proposal via the vault
    /// - Parameters:
    ///   - proposal: The proposal to vote on
    ///   - choice: The vote choice (yes, no, abstain)
    ///   - password: User's vault password for authorization
    /// - Returns: The vote receipt on success
    @discardableResult
    func castVote(on proposal: Proposal, choice: VoteChoice, password: String) async throws -> VoteReceipt {
        guard let authToken = authTokenProvider() else {
            throw VotingError.notAuthenticated
        }

        guard let natsManager = natsManager else {
            throw VotingError.natsNotConnected
        }

        guard let ownerSpace = ownerSpaceProvider() else {
            throw VotingError.noOwnerSpace
        }

        voteCastingState = .sendingToVault

        do {
            // 1. Hash the password
            let passwordHashResult = try PasswordHasher.hash(password: password)
            let passwordHashBase64 = passwordHashResult.hash.base64EncodedString()

            // 2. Generate a unique request ID
            let requestId = UUID().uuidString

            // 3. Create the vote request for the vault
            let voteRequest = VaultVoteRequest(
                id: requestId,
                proposalId: proposal.id,
                choice: choice.rawValue,
                passwordHash: passwordHashBase64,
                salt: passwordHashResult.salt.base64EncodedString(),
                timestamp: ISO8601DateFormatter().string(from: Date())
            )

            // 4. Subscribe to the response topic
            let responseTopic = "\(ownerSpace).forApp.vote.result.>"
            let responseStream = try await natsManager.subscribe(to: responseTopic)

            // 5. Send vote request to vault via NATS
            let requestTopic = "\(ownerSpace).forVault.vote.cast"
            try await natsManager.publish(voteRequest, to: requestTopic)

            voteCastingState = .waitingForSignature

            #if DEBUG
            print("[Voting] Sent vote request to \(requestTopic)")
            #endif

            // 6. Wait for vault response with timeout
            let voteTimeout: TimeInterval = 30
            let vaultResponse: VaultVoteResponse = try await withThrowingTaskGroup(of: VaultVoteResponse.self) { group in
                // Response listener
                group.addTask {
                    for await message in responseStream {
                        if let response = try? JSONDecoder().decode(VaultVoteResponse.self, from: message.data) {
                            if response.requestId == nil || response.requestId == requestId {
                                return response
                            }
                        }
                    }
                    throw VotingError.vaultResponseStreamEnded
                }

                // Timeout
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(voteTimeout * 1_000_000_000))
                    throw VotingError.timeout
                }

                guard let result = try await group.next() else {
                    throw VotingError.vaultNoResponse
                }

                group.cancelAll()
                return result
            }

            // 7. Check vault response
            guard vaultResponse.success else {
                throw VotingError.vaultError(vaultResponse.message ?? "Vote signing failed")
            }

            guard let receipt = vaultResponse.receipt else {
                throw VotingError.noReceipt
            }

            voteCastingState = .submittingToBackend

            // 8. Submit the signed vote to the backend
            let signedVote = SignedVoteSubmission(
                proposalId: proposal.id,
                choice: choice.rawValue,
                nonce: receipt.nonce,
                votingPublicKey: receipt.votingPublicKey,
                signature: receipt.signature,
                voteHash: receipt.voteHash,
                timestamp: receipt.timestamp
            )

            let submitResponse = try await apiClient.submitSignedVote(
                proposalId: proposal.id,
                signedVote: signedVote,
                authToken: authToken
            )

            guard submitResponse.success else {
                throw VotingError.backendError(submitResponse.message ?? "Vote submission failed")
            }

            // 9. Create and store the vote receipt locally
            let localReceipt = VoteReceipt(
                proposalId: proposal.id,
                proposalNumber: proposal.proposalNumber,
                proposalTitle: proposal.proposalTitle,
                choice: choice,
                nonce: receipt.nonce,
                votingPublicKey: receipt.votingPublicKey,
                voteHash: receipt.voteHash,
                timestamp: Date()
            )

            try voteReceiptStore.store(localReceipt)

            voteCastingState = .complete

            #if DEBUG
            print("[Voting] Vote cast successfully, hash: \(receipt.voteHash)")
            #endif

            return localReceipt

        } catch {
            voteCastingState = .error(error.localizedDescription)
            throw error
        }
    }

    /// Reset the vote casting state
    func resetVoteCastingState() {
        voteCastingState = .idle
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

// MARK: - Voting Errors

enum VotingError: LocalizedError {
    case notAuthenticated
    case natsNotConnected
    case noOwnerSpace
    case timeout
    case vaultResponseStreamEnded
    case vaultNoResponse
    case vaultError(String)
    case noReceipt
    case backendError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated"
        case .natsNotConnected:
            return "Not connected to vault messaging"
        case .noOwnerSpace:
            return "Owner space not configured"
        case .timeout:
            return "Vote request timed out"
        case .vaultResponseStreamEnded:
            return "Lost connection to vault"
        case .vaultNoResponse:
            return "No response from vault"
        case .vaultError(let message):
            return "Vault error: \(message)"
        case .noReceipt:
            return "No vote receipt returned"
        case .backendError(let message):
            return "Backend error: \(message)"
        }
    }
}

// MARK: - Vault Vote Request/Response

/// Request sent to vault via NATS to cast a vote
struct VaultVoteRequest: Encodable {
    let id: String
    let proposalId: String
    let choice: String
    let passwordHash: String
    let salt: String
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case id
        case proposalId = "proposal_id"
        case choice
        case passwordHash = "password_hash"
        case salt
        case timestamp
    }
}

/// Response from vault with signed vote
struct VaultVoteResponse: Decodable {
    let success: Bool
    let message: String?
    let requestId: String?
    let receipt: VaultVoteReceipt?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case requestId = "request_id"
        case receipt
    }
}

/// Vote receipt from vault containing signature
struct VaultVoteReceipt: Decodable {
    let nonce: String
    let votingPublicKey: String
    let signature: String
    let voteHash: String
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case nonce
        case votingPublicKey = "voting_public_key"
        case signature
        case voteHash = "vote_hash"
        case timestamp
    }
}
