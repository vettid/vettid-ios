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
    /// Phase 5.1: injected by ProposalsView via `.task` from
    /// AppState.ownerSpaceClient. The vault-mediated `vote.cast` path
    /// routes through here so the envelope gets the replay headers
    /// from Phase 0.1 and the encrypted-credential blob from 0.7
    /// without bespoke wiring.
    var ownerSpaceClient: OwnerSpaceClient?

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

    /// Cast a vote on a proposal via the vault (Phase 5.1 — fully
    /// vault-mediated).
    ///
    /// The flow used to be: app hashes the password, vault signs the
    /// vote, app POSTs the signed vote to the backend. Android moved
    /// the submission inside the vault — `vote.cast` now both signs
    /// AND submits — so the app's job is just to hand the vault the
    /// password envelope + the choice and trust the vault for the rest.
    ///
    /// Routes through `OwnerSpaceClient.sendAndAwaitResponse` so the
    /// envelope picks up timestamp_ms + nonce (Phase 0.1) and the
    /// encrypted-credential blob (Phase 0.7) automatically.
    @discardableResult
    func castVote(on proposal: Proposal, choice: VoteChoice, password: String) async throws -> VoteReceipt {
        guard let osc = ownerSpaceClient else {
            throw VotingError.natsNotConnected
        }

        voteCastingState = .sendingToVault
        do {
            // 1. Hash the password with Argon2id and encrypt the hash
            //    under a fresh UTK — same envelope shape every other
            //    password-gated call site uses (matches Phase 3's
            //    PasswordApprovalEnvelope flow).
            let envelope = try PasswordApprovalEnvelope.build(password: password)

            // 2. Build the vault payload. `encrypted_credential` is
            //    added automatically by SecretsClient/GrantsClient via
            //    Phase 0.7's shared helper, but vote.cast lives on a
            //    different surface; we attach it here.
            var payload: [String: AnyCodableValue] = [
                "proposal_id":            AnyCodableValue(proposal.id),
                "choice":                 AnyCodableValue(choice.rawValue),
                "encrypted_password_hash": AnyCodableValue(envelope.encryptedPasswordHash),
                "ephemeral_public_key":   AnyCodableValue(envelope.ephemeralPublicKey),
                "nonce":                  AnyCodableValue(envelope.nonce),
                "salt":                   AnyCodableValue(envelope.salt)
            ]
            if let utk = envelope.utkKeyId {
                payload["key_id"] = AnyCodableValue(utk)
            }
            if let blob = try? ProteanCredentialStore().encryptedBlobBase64() {
                payload["encrypted_credential"] = AnyCodableValue(blob)
            }

            voteCastingState = .waitingForSignature

            // 3. Fire vote.cast through OwnerSpaceClient — replay-safe
            //    envelope, JetStream request-response, single round-trip.
            let response = try await osc.sendAndAwaitResponse(
                "vote.cast",
                payload: payload,
                timeout: 30
            )
            guard response.success else {
                throw VotingError.vaultError(response.error ?? "Vote casting failed")
            }

            // 4. Read the receipt the vault built. Vault already
            //    submitted the signed vote to the backend by this
            //    point, so there's no follow-up POST.
            let result = response.result ?? [:]
            let nonce       = result["nonce"]        as? String ?? UUID().uuidString
            let votingKey   = result["voting_public_key"] as? String ?? ""
            let voteHash    = result["vote_hash"]    as? String ?? ""
            let timestampMs = result["timestamp_ms"] as? Double
                ?? (result["timestamp_ms"] as? Int).map(Double.init)
                ?? Date().timeIntervalSince1970 * 1000

            // 5. Store the receipt locally so "Verify my vote" can
            //    re-walk the Merkle proof.
            let localReceipt = VoteReceipt(
                proposalId: proposal.id,
                proposalNumber: proposal.proposalNumber,
                proposalTitle: proposal.proposalTitle,
                choice: choice,
                nonce: nonce,
                votingPublicKey: votingKey,
                voteHash: voteHash,
                timestamp: Date(timeIntervalSince1970: timestampMs / 1000)
            )
            try voteReceiptStore.store(localReceipt)

            voteCastingState = .complete
            #if DEBUG
            print("[Voting] Vote cast (vault-mediated). hash=\(voteHash)")
            #endif
            return localReceipt
        } catch {
            voteCastingState = .error(error.localizedDescription)
            throw error
        }
    }

    /// Ask the vault to re-derive my voting key, fetch the inclusion
    /// proof, and re-walk the Merkle tree inside the enclave — the
    /// "Verify my vote" affordance (Phase 5.1). Returns true on success.
    /// Mirrors Android's `vote.verify`.
    func verifyVote(proposalId: String, voteHash: String) async throws -> Bool {
        guard let osc = ownerSpaceClient else {
            throw VotingError.natsNotConnected
        }
        let payload: [String: AnyCodableValue] = [
            "proposal_id": AnyCodableValue(proposalId),
            "vote_hash":   AnyCodableValue(voteHash)
        ]
        let response = try await osc.sendAndAwaitResponse(
            "vote.verify", payload: payload, timeout: 15
        )
        guard response.success else {
            throw VotingError.vaultError(response.error ?? "Verify failed")
        }
        return (response.result?["verified"] as? Bool) ?? false
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
    /// Phase D: encrypted credential blob; vault decrypts in-flight rather
    /// than reading `vaultState.credential`. Omitted only when the device
    /// has no credential stored (pre-enrollment), which can't reach vote.cast
    /// anyway.
    let encryptedCredential: String?

    enum CodingKeys: String, CodingKey {
        case id
        case proposalId = "proposal_id"
        case choice
        case passwordHash = "password_hash"
        case salt
        case timestamp
        case encryptedCredential = "encrypted_credential"
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
