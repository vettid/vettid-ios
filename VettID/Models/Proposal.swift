import Foundation

/// Represents a voting proposal from the organization
struct Proposal: Codable, Identifiable, Equatable {
    let id: String
    let proposalNumber: String
    let proposalTitle: String
    let proposalText: String
    let opensAt: Date
    let closesAt: Date
    let category: String?
    let quorumType: String?
    let quorumValue: Int?
    let createdAt: Date

    // Signature fields
    let signedPayload: String?
    let orgSignature: String?
    let signingKeyId: String?

    // Results (populated after voting closes)
    let merkleRoot: String?
    let voteListUrl: String?
    let resultsYes: Int?
    let resultsNo: Int?
    let resultsAbstain: Int?

    // Computed status
    var status: ProposalStatus {
        let now = Date()
        if now < opensAt {
            return .upcoming
        } else if now >= opensAt && now < closesAt {
            return .open
        } else {
            return .closed
        }
    }

    var totalVotes: Int {
        (resultsYes ?? 0) + (resultsNo ?? 0) + (resultsAbstain ?? 0)
    }

    var hasResults: Bool {
        resultsYes != nil || resultsNo != nil || resultsAbstain != nil
    }
}

/// Proposal status based on dates
enum ProposalStatus: String, Codable {
    case upcoming
    case open
    case closed

    var displayName: String {
        switch self {
        case .upcoming: return "Upcoming"
        case .open: return "Open"
        case .closed: return "Closed"
        }
    }

    var systemImage: String {
        switch self {
        case .upcoming: return "clock"
        case .open: return "checkmark.circle"
        case .closed: return "lock"
        }
    }
}

/// Vote choice options
enum VoteChoice: String, Codable, CaseIterable {
    case yes
    case no
    case abstain

    var displayName: String {
        switch self {
        case .yes: return "Yes"
        case .no: return "No"
        case .abstain: return "Abstain"
        }
    }

    var systemImage: String {
        switch self {
        case .yes: return "hand.thumbsup.fill"
        case .no: return "hand.thumbsdown.fill"
        case .abstain: return "minus.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .yes: return "green"
        case .no: return "red"
        case .abstain: return "gray"
        }
    }
}

/// Response from fetching proposals
struct ProposalListResponse: Decodable {
    let proposals: [Proposal]
    let total: Int
}

/// Published vote for verification (anonymized)
struct PublishedVote: Codable, Identifiable, Equatable {
    var id: String { voteHash }
    let voteHash: String
    let choice: VoteChoice
    let votingPublicKey: String
    let signature: String
    let timestamp: Date
}

/// Published vote list (after polls close)
struct PublishedVoteList: Codable {
    let proposalId: String
    let merkleRoot: String
    let votes: [PublishedVote]
    let summary: VoteSummary
}

/// Vote summary counts
struct VoteSummary: Codable {
    let yes: Int
    let no: Int
    let abstain: Int
    let total: Int
}

/// Merkle proof for vote verification
struct MerkleProof: Codable {
    let voteHash: String
    let proof: [String]
    let root: String
    let index: Int
}

/// Response when requesting Merkle proof
struct MerkleProofResponse: Decodable {
    let proof: MerkleProof
}
