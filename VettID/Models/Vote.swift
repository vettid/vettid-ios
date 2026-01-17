import Foundation

/// Represents a vote receipt stored locally after casting a vote
/// This contains the nonce needed to find the user's vote in the published list
struct VoteReceipt: Codable, Identifiable, Equatable {
    var id: String { "\(proposalId)-\(nonce)" }
    let proposalId: String
    let proposalNumber: String
    let proposalTitle: String
    let choice: VoteChoice
    let nonce: String
    let votingPublicKey: String
    let voteHash: String
    let timestamp: Date

    // Verification status (updated after proposal closes)
    var isVerified: Bool?
    var verifiedAt: Date?
}

/// Request to cast a vote via vault operation
struct CastVoteRequest: Encodable {
    let proposalId: String
    let choice: String
}

/// Response from casting a vote
struct CastVoteResponse: Decodable {
    let success: Bool
    let receipt: VoteReceiptDTO
    let newCredential: CredentialPackage?

    struct VoteReceiptDTO: Decodable {
        let proposalId: String
        let choice: String
        let nonce: String
        let votingPublicKey: String
        let voteHash: String
        let timestamp: String
    }
}

/// Vault operation request wrapper for voting
struct VaultOperationRequest: Encodable {
    let sealedCredential: String
    let operation: String
    let params: [String: String]
    let encryptedPasswordHash: String
    let ephemeralPublicKey: String
    let nonce: String
    let keyId: String
}

/// Challenge response when vault requires password
struct VaultChallengeResponse: Decodable {
    let challengeId: String
    let utkId: String
    let message: String
}

/// Vote verification result
struct VoteVerificationResult: Equatable {
    let signatureValid: Bool
    let foundInList: Bool
    let includedInMerkle: Bool
    let merkleRootMatches: Bool

    var isFullyVerified: Bool {
        signatureValid && foundInList && includedInMerkle && merkleRootMatches
    }

    static let unverified = VoteVerificationResult(
        signatureValid: false,
        foundInList: false,
        includedInMerkle: false,
        merkleRootMatches: false
    )
}

/// Signature verification result for proposals
struct ProposalSignatureStatus: Equatable {
    let isVerified: Bool
    let verifiedAt: Date?
    let error: String?

    static let unverified = ProposalSignatureStatus(isVerified: false, verifiedAt: nil, error: nil)
    static let verified = ProposalSignatureStatus(isVerified: true, verifiedAt: Date(), error: nil)

    static func failed(_ error: String) -> ProposalSignatureStatus {
        ProposalSignatureStatus(isVerified: false, verifiedAt: nil, error: error)
    }
}
