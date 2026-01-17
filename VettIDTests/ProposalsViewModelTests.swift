import XCTest
@testable import VettID

/// Tests for ProposalsViewModel
@MainActor
final class ProposalsViewModelTests: XCTestCase {

    // MARK: - Helper

    private func createTestProposal(
        id: String = "test-proposal-1",
        proposalNumber: String = "P0001",
        proposalTitle: String = "Test Proposal",
        status: ProposalStatus = .open
    ) -> Proposal {
        let now = Date()
        let opensAt: Date
        let closesAt: Date

        switch status {
        case .upcoming:
            opensAt = now.addingTimeInterval(86400)  // Opens tomorrow
            closesAt = now.addingTimeInterval(86400 * 7)
        case .open:
            opensAt = now.addingTimeInterval(-86400)  // Opened yesterday
            closesAt = now.addingTimeInterval(86400 * 6)  // Closes in 6 days
        case .closed:
            opensAt = now.addingTimeInterval(-86400 * 7)  // Opened 7 days ago
            closesAt = now.addingTimeInterval(-86400)  // Closed yesterday
        }

        return Proposal(
            id: id,
            proposalNumber: proposalNumber,
            proposalTitle: proposalTitle,
            proposalText: "This is a test proposal description.",
            opensAt: opensAt,
            closesAt: closesAt,
            category: "Test",
            quorumType: "majority",
            quorumValue: 50,
            createdAt: now.addingTimeInterval(-86400 * 14),
            signedPayload: nil,
            orgSignature: nil,
            signingKeyId: nil,
            merkleRoot: nil,
            voteListUrl: nil,
            resultsYes: nil,
            resultsNo: nil,
            resultsAbstain: nil
        )
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        let viewModel = ProposalsViewModel(authTokenProvider: { "test-token" })

        if case .loading = viewModel.state {
            // Expected initial state
        } else {
            XCTFail("Expected loading state, got \(viewModel.state)")
        }
        XCTAssertEqual(viewModel.selectedFilter, .all)
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Authentication Tests

    func testLoadProposals_noAuthToken() async {
        let viewModel = ProposalsViewModel(authTokenProvider: { nil })

        await viewModel.loadProposals()

        if case .error(let message) = viewModel.state {
            XCTAssertEqual(message, "Not authenticated")
        } else {
            XCTFail("Expected error state")
        }
    }

    // MARK: - Filter Tests

    func testSelectedFilter_defaultIsAll() {
        let viewModel = ProposalsViewModel(authTokenProvider: { "test-token" })
        XCTAssertEqual(viewModel.selectedFilter, .all)
    }

    func testUpdateFilter() {
        let viewModel = ProposalsViewModel(authTokenProvider: { "test-token" })

        viewModel.updateFilter(.open)
        XCTAssertEqual(viewModel.selectedFilter, .open)

        viewModel.updateFilter(.closed)
        XCTAssertEqual(viewModel.selectedFilter, .closed)

        viewModel.updateFilter(.upcoming)
        XCTAssertEqual(viewModel.selectedFilter, .upcoming)

        viewModel.updateFilter(.all)
        XCTAssertEqual(viewModel.selectedFilter, .all)
    }

    // MARK: - Signature Status Tests

    func testSignatureStatus_unverified() {
        let viewModel = ProposalsViewModel(authTokenProvider: { "test-token" })
        let proposal = createTestProposal()

        let status = viewModel.signatureStatus(for: proposal)

        XCTAssertFalse(status.isVerified)
        XCTAssertNil(status.verifiedAt)
        XCTAssertNil(status.error)
    }

    // MARK: - Error Handling Tests

    func testClearError() {
        let viewModel = ProposalsViewModel(authTokenProvider: { "test-token" })
        viewModel.errorMessage = "Test error"

        viewModel.clearError()

        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Has Voted Tests

    func testHasVoted_noReceipt() {
        let viewModel = ProposalsViewModel(authTokenProvider: { "test-token" })
        let proposal = createTestProposal()

        // Clean up any existing receipts
        VoteReceiptStore.shared.deleteAll()

        XCTAssertFalse(viewModel.hasVoted(on: proposal))
    }

    func testHasVoted_withReceipt() throws {
        let viewModel = ProposalsViewModel(authTokenProvider: { "test-token" })
        let proposal = createTestProposal(id: "voted-proposal")

        // Store a receipt
        let receipt = VoteReceipt(
            proposalId: proposal.id,
            proposalNumber: proposal.proposalNumber,
            proposalTitle: proposal.proposalTitle,
            choice: .yes,
            nonce: "test-nonce",
            votingPublicKey: "vk_test",
            voteHash: "hash123",
            timestamp: Date(),
            isVerified: nil,
            verifiedAt: nil
        )
        try VoteReceiptStore.shared.store(receipt)

        XCTAssertTrue(viewModel.hasVoted(on: proposal))

        // Cleanup
        VoteReceiptStore.shared.deleteAll()
    }

    // MARK: - Get Vote Receipt Tests

    func testGetVoteReceipt_exists() throws {
        let viewModel = ProposalsViewModel(authTokenProvider: { "test-token" })
        let proposal = createTestProposal(id: "receipt-proposal")

        let receipt = VoteReceipt(
            proposalId: proposal.id,
            proposalNumber: proposal.proposalNumber,
            proposalTitle: proposal.proposalTitle,
            choice: .no,
            nonce: "test-nonce",
            votingPublicKey: "vk_test",
            voteHash: "hash123",
            timestamp: Date(),
            isVerified: nil,
            verifiedAt: nil
        )
        try VoteReceiptStore.shared.store(receipt)

        let retrieved = viewModel.getVoteReceipt(for: proposal)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.choice, .no)

        // Cleanup
        VoteReceiptStore.shared.deleteAll()
    }

    func testGetVoteReceipt_notExists() {
        let viewModel = ProposalsViewModel(authTokenProvider: { "test-token" })
        let proposal = createTestProposal(id: "no-receipt-proposal")

        VoteReceiptStore.shared.deleteAll()

        let retrieved = viewModel.getVoteReceipt(for: proposal)
        XCTAssertNil(retrieved)
    }
}

// MARK: - ProposalFilter Tests

final class ProposalFilterTests: XCTestCase {

    func testAllCases() {
        let allCases = ProposalFilter.allCases
        XCTAssertEqual(allCases.count, 4)
        XCTAssertTrue(allCases.contains(.all))
        XCTAssertTrue(allCases.contains(.open))
        XCTAssertTrue(allCases.contains(.closed))
        XCTAssertTrue(allCases.contains(.upcoming))
    }

    func testRawValues() {
        XCTAssertEqual(ProposalFilter.all.rawValue, "All")
        XCTAssertEqual(ProposalFilter.open.rawValue, "Open")
        XCTAssertEqual(ProposalFilter.closed.rawValue, "Closed")
        XCTAssertEqual(ProposalFilter.upcoming.rawValue, "Upcoming")
    }
}
