import Foundation

/// Stores vote receipts locally for verification after polls close
/// Vote receipts contain the nonce needed to find the user's vote in the published list
final class VoteReceiptStore {

    // MARK: - Constants

    private let userDefaultsKey = "com.vettid.voteReceipts"

    // MARK: - Singleton

    static let shared = VoteReceiptStore()

    private init() {}

    // MARK: - Storage Operations

    /// Store a vote receipt after casting a vote
    func store(_ receipt: VoteReceipt) throws {
        var receipts = retrieveAll()

        // Remove any existing receipt for the same proposal (shouldn't happen, but safety check)
        receipts.removeAll { $0.proposalId == receipt.proposalId }

        receipts.append(receipt)
        try save(receipts)
    }

    /// Retrieve a vote receipt for a specific proposal
    func retrieve(forProposalId proposalId: String) -> VoteReceipt? {
        return retrieveAll().first { $0.proposalId == proposalId }
    }

    /// Retrieve all vote receipts
    func retrieveAll() -> [VoteReceipt] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([VoteReceipt].self, from: data)
        } catch {
            #if DEBUG
            print("[VoteReceiptStore] Failed to decode receipts: \(error)")
            #endif
            return []
        }
    }

    /// Update verification status for a receipt
    func updateVerificationStatus(
        forProposalId proposalId: String,
        isVerified: Bool
    ) throws {
        var receipts = retrieveAll()

        guard let index = receipts.firstIndex(where: { $0.proposalId == proposalId }) else {
            return
        }

        var receipt = receipts[index]
        receipt = VoteReceipt(
            proposalId: receipt.proposalId,
            proposalNumber: receipt.proposalNumber,
            proposalTitle: receipt.proposalTitle,
            choice: receipt.choice,
            nonce: receipt.nonce,
            votingPublicKey: receipt.votingPublicKey,
            voteHash: receipt.voteHash,
            timestamp: receipt.timestamp,
            isVerified: isVerified,
            verifiedAt: isVerified ? Date() : nil
        )

        receipts[index] = receipt
        try save(receipts)
    }

    /// Delete a vote receipt
    func delete(forProposalId proposalId: String) throws {
        var receipts = retrieveAll()
        receipts.removeAll { $0.proposalId == proposalId }
        try save(receipts)
    }

    /// Delete all vote receipts
    func deleteAll() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    /// Check if user has voted on a proposal
    func hasVoted(onProposalId proposalId: String) -> Bool {
        return retrieve(forProposalId: proposalId) != nil
    }

    /// Get receipts for proposals that are now closed and need verification
    func getUnverifiedReceipts() -> [VoteReceipt] {
        return retrieveAll().filter { $0.isVerified != true }
    }

    // MARK: - Private Helpers

    private func save(_ receipts: [VoteReceipt]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(receipts)
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
