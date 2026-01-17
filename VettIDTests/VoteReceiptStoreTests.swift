import XCTest
@testable import VettID

/// Tests for VoteReceiptStore
final class VoteReceiptStoreTests: XCTestCase {

    private var store: VoteReceiptStore!

    override func setUp() {
        super.setUp()
        store = VoteReceiptStore.shared
        // Clean up any existing test data
        store.deleteAll()
    }

    override func tearDown() {
        store.deleteAll()
        super.tearDown()
    }

    // MARK: - Helper

    private func createTestReceipt(
        proposalId: String = "test-proposal-1",
        proposalNumber: String = "P0001",
        proposalTitle: String = "Test Proposal",
        choice: VoteChoice = .yes,
        nonce: String = "test-nonce-123",
        votingPublicKey: String = "vk_test123",
        voteHash: String = "hash123"
    ) -> VoteReceipt {
        VoteReceipt(
            proposalId: proposalId,
            proposalNumber: proposalNumber,
            proposalTitle: proposalTitle,
            choice: choice,
            nonce: nonce,
            votingPublicKey: votingPublicKey,
            voteHash: voteHash,
            timestamp: Date(),
            isVerified: nil,
            verifiedAt: nil
        )
    }

    // MARK: - Storage Tests

    func testStoreAndRetrieveReceipt() throws {
        let receipt = createTestReceipt()

        try store.store(receipt)

        let retrieved = store.retrieve(forProposalId: receipt.proposalId)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.proposalId, receipt.proposalId)
        XCTAssertEqual(retrieved?.proposalNumber, receipt.proposalNumber)
        XCTAssertEqual(retrieved?.proposalTitle, receipt.proposalTitle)
        XCTAssertEqual(retrieved?.choice, receipt.choice)
        XCTAssertEqual(retrieved?.nonce, receipt.nonce)
        XCTAssertEqual(retrieved?.votingPublicKey, receipt.votingPublicKey)
        XCTAssertEqual(retrieved?.voteHash, receipt.voteHash)
    }

    func testStoreMultipleReceipts() throws {
        let receipt1 = createTestReceipt(proposalId: "proposal-1", proposalNumber: "P0001")
        let receipt2 = createTestReceipt(proposalId: "proposal-2", proposalNumber: "P0002")
        let receipt3 = createTestReceipt(proposalId: "proposal-3", proposalNumber: "P0003")

        try store.store(receipt1)
        try store.store(receipt2)
        try store.store(receipt3)

        let allReceipts = store.retrieveAll()
        XCTAssertEqual(allReceipts.count, 3)
    }

    func testStoreReplacesExistingReceipt() throws {
        let receipt1 = createTestReceipt(proposalId: "proposal-1", choice: .yes)
        let receipt2 = createTestReceipt(proposalId: "proposal-1", choice: .no)

        try store.store(receipt1)
        try store.store(receipt2)

        let allReceipts = store.retrieveAll()
        XCTAssertEqual(allReceipts.count, 1)

        let retrieved = store.retrieve(forProposalId: "proposal-1")
        XCTAssertEqual(retrieved?.choice, .no)
    }

    // MARK: - Retrieval Tests

    func testRetrieveNonExistentReceipt() {
        let retrieved = store.retrieve(forProposalId: "non-existent")
        XCTAssertNil(retrieved)
    }

    func testRetrieveAllEmpty() {
        let allReceipts = store.retrieveAll()
        XCTAssertTrue(allReceipts.isEmpty)
    }

    // MARK: - Has Voted Tests

    func testHasVoted_true() throws {
        let receipt = createTestReceipt(proposalId: "proposal-1")
        try store.store(receipt)

        XCTAssertTrue(store.hasVoted(onProposalId: "proposal-1"))
    }

    func testHasVoted_false() {
        XCTAssertFalse(store.hasVoted(onProposalId: "non-existent"))
    }

    // MARK: - Verification Status Tests

    func testUpdateVerificationStatus() throws {
        let receipt = createTestReceipt(proposalId: "proposal-1")
        try store.store(receipt)

        // Initially not verified
        let initial = store.retrieve(forProposalId: "proposal-1")
        XCTAssertNil(initial?.isVerified)
        XCTAssertNil(initial?.verifiedAt)

        // Update to verified
        try store.updateVerificationStatus(forProposalId: "proposal-1", isVerified: true)

        let updated = store.retrieve(forProposalId: "proposal-1")
        XCTAssertEqual(updated?.isVerified, true)
        XCTAssertNotNil(updated?.verifiedAt)
    }

    func testUpdateVerificationStatus_notVerified() throws {
        let receipt = createTestReceipt(proposalId: "proposal-1")
        try store.store(receipt)

        try store.updateVerificationStatus(forProposalId: "proposal-1", isVerified: false)

        let updated = store.retrieve(forProposalId: "proposal-1")
        XCTAssertEqual(updated?.isVerified, false)
        XCTAssertNil(updated?.verifiedAt)
    }

    func testUpdateVerificationStatus_nonExistent() throws {
        // Should not throw, just do nothing
        try store.updateVerificationStatus(forProposalId: "non-existent", isVerified: true)
    }

    // MARK: - Unverified Receipts Tests

    func testGetUnverifiedReceipts() throws {
        let receipt1 = createTestReceipt(proposalId: "proposal-1")
        let receipt2 = createTestReceipt(proposalId: "proposal-2")

        try store.store(receipt1)
        try store.store(receipt2)

        // Mark one as verified
        try store.updateVerificationStatus(forProposalId: "proposal-1", isVerified: true)

        let unverified = store.getUnverifiedReceipts()
        XCTAssertEqual(unverified.count, 1)
        XCTAssertEqual(unverified.first?.proposalId, "proposal-2")
    }

    // MARK: - Deletion Tests

    func testDeleteReceipt() throws {
        let receipt = createTestReceipt(proposalId: "proposal-1")
        try store.store(receipt)

        XCTAssertNotNil(store.retrieve(forProposalId: "proposal-1"))

        try store.delete(forProposalId: "proposal-1")

        XCTAssertNil(store.retrieve(forProposalId: "proposal-1"))
    }

    func testDeleteNonExistent() throws {
        // Should not throw
        try store.delete(forProposalId: "non-existent")
    }

    func testDeleteAll() throws {
        try store.store(createTestReceipt(proposalId: "proposal-1"))
        try store.store(createTestReceipt(proposalId: "proposal-2"))
        try store.store(createTestReceipt(proposalId: "proposal-3"))

        XCTAssertEqual(store.retrieveAll().count, 3)

        store.deleteAll()

        XCTAssertTrue(store.retrieveAll().isEmpty)
    }

    // MARK: - Vote Choice Tests

    func testAllVoteChoices() throws {
        for choice in VoteChoice.allCases {
            let proposalId = "proposal-\(choice.rawValue)"
            let receipt = createTestReceipt(proposalId: proposalId, choice: choice)
            try store.store(receipt)

            let retrieved = store.retrieve(forProposalId: proposalId)
            XCTAssertEqual(retrieved?.choice, choice)
        }
    }
}
