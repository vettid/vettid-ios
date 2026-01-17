import XCTest
@testable import VettID

/// Tests for Proposal model and related types
final class ProposalTests: XCTestCase {

    // MARK: - Helper

    private func createProposal(
        opensAt: Date,
        closesAt: Date,
        resultsYes: Int? = nil,
        resultsNo: Int? = nil,
        resultsAbstain: Int? = nil
    ) -> Proposal {
        Proposal(
            id: "test-proposal",
            proposalNumber: "P0001",
            proposalTitle: "Test Proposal",
            proposalText: "Test description",
            opensAt: opensAt,
            closesAt: closesAt,
            category: "Test",
            quorumType: "majority",
            quorumValue: 50,
            createdAt: Date(),
            signedPayload: nil,
            orgSignature: nil,
            signingKeyId: nil,
            merkleRoot: nil,
            voteListUrl: nil,
            resultsYes: resultsYes,
            resultsNo: resultsNo,
            resultsAbstain: resultsAbstain
        )
    }

    // MARK: - Status Tests

    func testStatus_upcoming() {
        let now = Date()
        let proposal = createProposal(
            opensAt: now.addingTimeInterval(86400),  // Opens tomorrow
            closesAt: now.addingTimeInterval(86400 * 7)
        )

        XCTAssertEqual(proposal.status, .upcoming)
    }

    func testStatus_open() {
        let now = Date()
        let proposal = createProposal(
            opensAt: now.addingTimeInterval(-86400),  // Opened yesterday
            closesAt: now.addingTimeInterval(86400)   // Closes tomorrow
        )

        XCTAssertEqual(proposal.status, .open)
    }

    func testStatus_closed() {
        let now = Date()
        let proposal = createProposal(
            opensAt: now.addingTimeInterval(-86400 * 7),  // Opened 7 days ago
            closesAt: now.addingTimeInterval(-86400)      // Closed yesterday
        )

        XCTAssertEqual(proposal.status, .closed)
    }

    func testStatus_openAtExactOpenTime() {
        let now = Date()
        let proposal = createProposal(
            opensAt: now,  // Opens exactly now
            closesAt: now.addingTimeInterval(86400)
        )

        XCTAssertEqual(proposal.status, .open)
    }

    func testStatus_closedAtExactCloseTime() {
        let now = Date()
        let proposal = createProposal(
            opensAt: now.addingTimeInterval(-86400),
            closesAt: now  // Closes exactly now
        )

        XCTAssertEqual(proposal.status, .closed)
    }

    // MARK: - Total Votes Tests

    func testTotalVotes_noResults() {
        let proposal = createProposal(
            opensAt: Date(),
            closesAt: Date().addingTimeInterval(86400)
        )

        XCTAssertEqual(proposal.totalVotes, 0)
    }

    func testTotalVotes_withResults() {
        let proposal = createProposal(
            opensAt: Date().addingTimeInterval(-86400),
            closesAt: Date().addingTimeInterval(-3600),
            resultsYes: 100,
            resultsNo: 50,
            resultsAbstain: 25
        )

        XCTAssertEqual(proposal.totalVotes, 175)
    }

    func testTotalVotes_partialResults() {
        let proposal = createProposal(
            opensAt: Date().addingTimeInterval(-86400),
            closesAt: Date().addingTimeInterval(-3600),
            resultsYes: 100,
            resultsNo: nil,
            resultsAbstain: 25
        )

        XCTAssertEqual(proposal.totalVotes, 125)
    }

    // MARK: - Has Results Tests

    func testHasResults_true() {
        let proposal = createProposal(
            opensAt: Date().addingTimeInterval(-86400),
            closesAt: Date().addingTimeInterval(-3600),
            resultsYes: 100,
            resultsNo: 50,
            resultsAbstain: 25
        )

        XCTAssertTrue(proposal.hasResults)
    }

    func testHasResults_false() {
        let proposal = createProposal(
            opensAt: Date(),
            closesAt: Date().addingTimeInterval(86400)
        )

        XCTAssertFalse(proposal.hasResults)
    }

    func testHasResults_partiallyTrue() {
        let proposal = createProposal(
            opensAt: Date().addingTimeInterval(-86400),
            closesAt: Date().addingTimeInterval(-3600),
            resultsYes: 100,
            resultsNo: nil,
            resultsAbstain: nil
        )

        XCTAssertTrue(proposal.hasResults)
    }

    // MARK: - Equatable Tests

    func testProposalEquatable() {
        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        let opensAt = fixedDate
        let closesAt = fixedDate.addingTimeInterval(86400)

        let proposal1 = Proposal(
            id: "test-proposal",
            proposalNumber: "P0001",
            proposalTitle: "Test Proposal",
            proposalText: "Test description",
            opensAt: opensAt,
            closesAt: closesAt,
            category: "Test",
            quorumType: "majority",
            quorumValue: 50,
            createdAt: fixedDate,
            signedPayload: nil,
            orgSignature: nil,
            signingKeyId: nil,
            merkleRoot: nil,
            voteListUrl: nil,
            resultsYes: nil,
            resultsNo: nil,
            resultsAbstain: nil
        )
        let proposal2 = Proposal(
            id: "test-proposal",
            proposalNumber: "P0001",
            proposalTitle: "Test Proposal",
            proposalText: "Test description",
            opensAt: opensAt,
            closesAt: closesAt,
            category: "Test",
            quorumType: "majority",
            quorumValue: 50,
            createdAt: fixedDate,
            signedPayload: nil,
            orgSignature: nil,
            signingKeyId: nil,
            merkleRoot: nil,
            voteListUrl: nil,
            resultsYes: nil,
            resultsNo: nil,
            resultsAbstain: nil
        )

        // Same values should be equal
        XCTAssertEqual(proposal1, proposal2)
    }
}

// MARK: - ProposalStatus Tests

final class ProposalStatusTests: XCTestCase {

    func testDisplayName() {
        XCTAssertEqual(ProposalStatus.upcoming.displayName, "Upcoming")
        XCTAssertEqual(ProposalStatus.open.displayName, "Open")
        XCTAssertEqual(ProposalStatus.closed.displayName, "Closed")
    }

    func testSystemImage() {
        XCTAssertEqual(ProposalStatus.upcoming.systemImage, "clock")
        XCTAssertEqual(ProposalStatus.open.systemImage, "checkmark.circle")
        XCTAssertEqual(ProposalStatus.closed.systemImage, "lock")
    }
}

// MARK: - VoteChoice Tests

final class VoteChoiceTests: XCTestCase {

    func testAllCases() {
        let allCases = VoteChoice.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.yes))
        XCTAssertTrue(allCases.contains(.no))
        XCTAssertTrue(allCases.contains(.abstain))
    }

    func testRawValues() {
        XCTAssertEqual(VoteChoice.yes.rawValue, "yes")
        XCTAssertEqual(VoteChoice.no.rawValue, "no")
        XCTAssertEqual(VoteChoice.abstain.rawValue, "abstain")
    }

    func testDisplayName() {
        XCTAssertEqual(VoteChoice.yes.displayName, "Yes")
        XCTAssertEqual(VoteChoice.no.displayName, "No")
        XCTAssertEqual(VoteChoice.abstain.displayName, "Abstain")
    }

    func testSystemImage() {
        XCTAssertEqual(VoteChoice.yes.systemImage, "hand.thumbsup.fill")
        XCTAssertEqual(VoteChoice.no.systemImage, "hand.thumbsdown.fill")
        XCTAssertEqual(VoteChoice.abstain.systemImage, "minus.circle.fill")
    }

    func testColor() {
        XCTAssertEqual(VoteChoice.yes.color, "green")
        XCTAssertEqual(VoteChoice.no.color, "red")
        XCTAssertEqual(VoteChoice.abstain.color, "gray")
    }

    func testCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for choice in VoteChoice.allCases {
            let encoded = try encoder.encode(choice)
            let decoded = try decoder.decode(VoteChoice.self, from: encoded)
            XCTAssertEqual(decoded, choice)
        }
    }
}

// MARK: - VoteReceipt Tests

final class VoteReceiptTests: XCTestCase {

    func testId() {
        let receipt = VoteReceipt(
            proposalId: "proposal-123",
            proposalNumber: "P0001",
            proposalTitle: "Test",
            choice: .yes,
            nonce: "nonce-456",
            votingPublicKey: "vk_test",
            voteHash: "hash123",
            timestamp: Date(),
            isVerified: nil,
            verifiedAt: nil
        )

        XCTAssertEqual(receipt.id, "proposal-123-nonce-456")
    }

    func testCodable() throws {
        let receipt = VoteReceipt(
            proposalId: "proposal-123",
            proposalNumber: "P0001",
            proposalTitle: "Test Proposal",
            choice: .no,
            nonce: "test-nonce",
            votingPublicKey: "vk_abc123",
            voteHash: "hash456",
            timestamp: Date(),
            isVerified: true,
            verifiedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(receipt)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VoteReceipt.self, from: encoded)

        XCTAssertEqual(decoded.proposalId, receipt.proposalId)
        XCTAssertEqual(decoded.proposalNumber, receipt.proposalNumber)
        XCTAssertEqual(decoded.proposalTitle, receipt.proposalTitle)
        XCTAssertEqual(decoded.choice, receipt.choice)
        XCTAssertEqual(decoded.nonce, receipt.nonce)
        XCTAssertEqual(decoded.votingPublicKey, receipt.votingPublicKey)
        XCTAssertEqual(decoded.voteHash, receipt.voteHash)
        XCTAssertEqual(decoded.isVerified, receipt.isVerified)
    }
}

// MARK: - VoteVerificationResult Tests

final class VoteVerificationResultTests: XCTestCase {

    func testIsFullyVerified_allTrue() {
        let result = VoteVerificationResult(
            signatureValid: true,
            foundInList: true,
            includedInMerkle: true,
            merkleRootMatches: true
        )

        XCTAssertTrue(result.isFullyVerified)
    }

    func testIsFullyVerified_oneFailure() {
        let result = VoteVerificationResult(
            signatureValid: true,
            foundInList: true,
            includedInMerkle: false,
            merkleRootMatches: true
        )

        XCTAssertFalse(result.isFullyVerified)
    }

    func testUnverified() {
        let result = VoteVerificationResult.unverified

        XCTAssertFalse(result.signatureValid)
        XCTAssertFalse(result.foundInList)
        XCTAssertFalse(result.includedInMerkle)
        XCTAssertFalse(result.merkleRootMatches)
        XCTAssertFalse(result.isFullyVerified)
    }
}

// MARK: - ProposalSignatureStatus Tests

final class ProposalSignatureStatusTests: XCTestCase {

    func testUnverified() {
        let status = ProposalSignatureStatus.unverified

        XCTAssertFalse(status.isVerified)
        XCTAssertNil(status.verifiedAt)
        XCTAssertNil(status.error)
    }

    func testVerified() {
        let status = ProposalSignatureStatus.verified

        XCTAssertTrue(status.isVerified)
        XCTAssertNotNil(status.verifiedAt)
        XCTAssertNil(status.error)
    }

    func testFailed() {
        let status = ProposalSignatureStatus.failed("Test error")

        XCTAssertFalse(status.isVerified)
        XCTAssertNil(status.verifiedAt)
        XCTAssertEqual(status.error, "Test error")
    }
}

// MARK: - PublishedVote Tests

final class PublishedVoteTests: XCTestCase {

    func testId() {
        let vote = PublishedVote(
            voteHash: "hash123",
            choice: .yes,
            votingPublicKey: "vk_test",
            signature: "sig_test",
            timestamp: Date()
        )

        XCTAssertEqual(vote.id, "hash123")
    }

    func testCodable() throws {
        let vote = PublishedVote(
            voteHash: "hash123",
            choice: .no,
            votingPublicKey: "vk_abc",
            signature: "sig_xyz",
            timestamp: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(vote)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PublishedVote.self, from: encoded)

        XCTAssertEqual(decoded.voteHash, vote.voteHash)
        XCTAssertEqual(decoded.choice, vote.choice)
        XCTAssertEqual(decoded.votingPublicKey, vote.votingPublicKey)
        XCTAssertEqual(decoded.signature, vote.signature)
    }
}

// MARK: - VoteSummary Tests

final class VoteSummaryTests: XCTestCase {

    func testCodable() throws {
        let summary = VoteSummary(yes: 100, no: 50, abstain: 25, total: 175)

        let encoded = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(VoteSummary.self, from: encoded)

        XCTAssertEqual(decoded.yes, 100)
        XCTAssertEqual(decoded.no, 50)
        XCTAssertEqual(decoded.abstain, 25)
        XCTAssertEqual(decoded.total, 175)
    }
}
