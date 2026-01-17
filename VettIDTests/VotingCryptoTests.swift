import XCTest
import CryptoKit
@testable import VettID

/// Tests for voting-related cryptographic operations in CryptoManager
final class VotingCryptoTests: XCTestCase {

    // MARK: - Voting Key Derivation Tests

    func testDeriveVotingKeyPair() throws {
        // Generate a test identity key (simulating user's Ed25519 identity)
        let identityPrivateKey = CryptoManager.randomBytes(count: 32)
        let proposalId = "proposal-123"

        let (privateKey, publicKey) = try CryptoManager.deriveVotingKeyPair(
            identityPrivateKey: identityPrivateKey,
            proposalId: proposalId
        )

        // Verify key sizes
        XCTAssertEqual(privateKey.rawRepresentation.count, 32, "Ed25519 private key should be 32 bytes")
        XCTAssertEqual(publicKey.rawRepresentation.count, 32, "Ed25519 public key should be 32 bytes")

        // Verify public key is derived from private key
        XCTAssertEqual(privateKey.publicKey.rawRepresentation, publicKey.rawRepresentation)
    }

    func testDeriveVotingKeyPair_deterministic() throws {
        let identityPrivateKey = CryptoManager.randomBytes(count: 32)
        let proposalId = "proposal-123"

        let (privateKey1, publicKey1) = try CryptoManager.deriveVotingKeyPair(
            identityPrivateKey: identityPrivateKey,
            proposalId: proposalId
        )

        let (privateKey2, publicKey2) = try CryptoManager.deriveVotingKeyPair(
            identityPrivateKey: identityPrivateKey,
            proposalId: proposalId
        )

        // Same inputs should produce same outputs
        XCTAssertEqual(privateKey1.rawRepresentation, privateKey2.rawRepresentation)
        XCTAssertEqual(publicKey1.rawRepresentation, publicKey2.rawRepresentation)
    }

    func testDeriveVotingKeyPair_differentProposals() throws {
        let identityPrivateKey = CryptoManager.randomBytes(count: 32)

        let (_, publicKey1) = try CryptoManager.deriveVotingKeyPair(
            identityPrivateKey: identityPrivateKey,
            proposalId: "proposal-1"
        )

        let (_, publicKey2) = try CryptoManager.deriveVotingKeyPair(
            identityPrivateKey: identityPrivateKey,
            proposalId: "proposal-2"
        )

        // Different proposals should produce different voting keys (unlinkable)
        XCTAssertNotEqual(
            publicKey1.rawRepresentation,
            publicKey2.rawRepresentation,
            "Voting keys for different proposals should be different"
        )
    }

    func testDeriveVotingKeyPair_differentIdentities() throws {
        let identity1 = CryptoManager.randomBytes(count: 32)
        let identity2 = CryptoManager.randomBytes(count: 32)
        let proposalId = "proposal-123"

        let (_, publicKey1) = try CryptoManager.deriveVotingKeyPair(
            identityPrivateKey: identity1,
            proposalId: proposalId
        )

        let (_, publicKey2) = try CryptoManager.deriveVotingKeyPair(
            identityPrivateKey: identity2,
            proposalId: proposalId
        )

        // Different identities should produce different voting keys
        XCTAssertNotEqual(
            publicKey1.rawRepresentation,
            publicKey2.rawRepresentation,
            "Voting keys for different identities should be different"
        )
    }

    func testDeriveVotingPublicKey() throws {
        let identityPrivateKey = CryptoManager.randomBytes(count: 32)
        let proposalId = "proposal-123"

        let publicKeyBase64 = try CryptoManager.deriveVotingPublicKey(
            identityPrivateKey: identityPrivateKey,
            proposalId: proposalId
        )

        // Verify it's valid base64
        XCTAssertNotNil(Data(base64Encoded: publicKeyBase64))

        // Verify it decodes to 32 bytes
        let decoded = Data(base64Encoded: publicKeyBase64)!
        XCTAssertEqual(decoded.count, 32)
    }

    func testDeriveVotingPublicKey_matchesKeyPair() throws {
        let identityPrivateKey = CryptoManager.randomBytes(count: 32)
        let proposalId = "proposal-123"

        let (_, publicKey) = try CryptoManager.deriveVotingKeyPair(
            identityPrivateKey: identityPrivateKey,
            proposalId: proposalId
        )

        let publicKeyBase64 = try CryptoManager.deriveVotingPublicKey(
            identityPrivateKey: identityPrivateKey,
            proposalId: proposalId
        )

        XCTAssertEqual(
            publicKey.rawRepresentation.base64EncodedString(),
            publicKeyBase64
        )
    }

    // MARK: - Voting Signature Tests

    func testVotingSignature() throws {
        let identityPrivateKey = CryptoManager.randomBytes(count: 32)
        let proposalId = "proposal-123"

        let (votingPrivateKey, votingPublicKey) = try CryptoManager.deriveVotingKeyPair(
            identityPrivateKey: identityPrivateKey,
            proposalId: proposalId
        )

        // Create a vote payload
        let votePayload = """
        {"proposal_id":"\(proposalId)","choice":"yes","timestamp":1234567890}
        """.data(using: .utf8)!

        // Sign with voting key
        let signature = try CryptoManager.sign(data: votePayload, privateKey: votingPrivateKey)

        // Verify signature
        XCTAssertTrue(
            CryptoManager.verify(signature: signature, for: votePayload, publicKey: votingPublicKey),
            "Vote signature should be valid"
        )
    }

    func testVotingSignature_invalidWithDifferentKey() throws {
        let identityPrivateKey = CryptoManager.randomBytes(count: 32)

        let (votingPrivateKey, _) = try CryptoManager.deriveVotingKeyPair(
            identityPrivateKey: identityPrivateKey,
            proposalId: "proposal-1"
        )

        let (_, wrongPublicKey) = try CryptoManager.deriveVotingKeyPair(
            identityPrivateKey: identityPrivateKey,
            proposalId: "proposal-2"  // Different proposal = different key
        )

        let votePayload = "test vote".data(using: .utf8)!
        let signature = try CryptoManager.sign(data: votePayload, privateKey: votingPrivateKey)

        XCTAssertFalse(
            CryptoManager.verify(signature: signature, for: votePayload, publicKey: wrongPublicKey),
            "Signature should not verify with wrong public key"
        )
    }

    // MARK: - Merkle Proof Verification Tests

    func testVerifyMerkleProof_validProof() {
        // Create a simple Merkle tree for testing
        // Tree structure:
        //       root
        //      /    \
        //   hash01   hash23
        //   /  \     /  \
        //  v0  v1   v2  v3
        //
        // To prove v0 is in tree, proof = [v1, hash23], index = 0

        let v0 = Data(SHA256.hash(data: "vote0".data(using: .utf8)!))
        let v1 = Data(SHA256.hash(data: "vote1".data(using: .utf8)!))
        let v2 = Data(SHA256.hash(data: "vote2".data(using: .utf8)!))
        let v3 = Data(SHA256.hash(data: "vote3".data(using: .utf8)!))

        let hash01 = Data(SHA256.hash(data: v0 + v1))
        let hash23 = Data(SHA256.hash(data: v2 + v3))
        let root = Data(SHA256.hash(data: hash01 + hash23))

        // Proof for v0: need v1 and hash23
        let proof = [v1.base64EncodedString(), hash23.base64EncodedString()]

        let isValid = CryptoManager.verifyMerkleProof(
            voteHash: v0.base64EncodedString(),
            proof: proof,
            root: root.base64EncodedString(),
            index: 0
        )

        XCTAssertTrue(isValid, "Valid Merkle proof should verify")
    }

    func testVerifyMerkleProof_invalidRoot() {
        let v0 = Data(SHA256.hash(data: "vote0".data(using: .utf8)!))
        let v1 = Data(SHA256.hash(data: "vote1".data(using: .utf8)!))

        let proof = [v1.base64EncodedString()]
        let wrongRoot = Data(SHA256.hash(data: "wrong".data(using: .utf8)!))

        let isValid = CryptoManager.verifyMerkleProof(
            voteHash: v0.base64EncodedString(),
            proof: proof,
            root: wrongRoot.base64EncodedString(),
            index: 0
        )

        XCTAssertFalse(isValid, "Proof with wrong root should not verify")
    }

    func testVerifyMerkleProof_invalidVoteHash() {
        let v0 = Data(SHA256.hash(data: "vote0".data(using: .utf8)!))
        let v1 = Data(SHA256.hash(data: "vote1".data(using: .utf8)!))
        let wrongVote = Data(SHA256.hash(data: "wrong".data(using: .utf8)!))

        let hash01 = Data(SHA256.hash(data: v0 + v1))

        let proof = [v1.base64EncodedString()]

        let isValid = CryptoManager.verifyMerkleProof(
            voteHash: wrongVote.base64EncodedString(),
            proof: proof,
            root: hash01.base64EncodedString(),
            index: 0
        )

        XCTAssertFalse(isValid, "Proof with wrong vote hash should not verify")
    }

    func testVerifyMerkleProof_invalidBase64() {
        let isValid = CryptoManager.verifyMerkleProof(
            voteHash: "not-valid-base64!!!",
            proof: ["also-invalid"],
            root: "invalid-root",
            index: 0
        )

        XCTAssertFalse(isValid, "Invalid base64 should return false")
    }

    func testVerifyMerkleProof_emptyProof() {
        // Single element tree (vote is the root)
        let vote = Data(SHA256.hash(data: "only-vote".data(using: .utf8)!))

        let isValid = CryptoManager.verifyMerkleProof(
            voteHash: vote.base64EncodedString(),
            proof: [],
            root: vote.base64EncodedString(),
            index: 0
        )

        XCTAssertTrue(isValid, "Single element tree should verify with empty proof")
    }

    func testVerifyMerkleProof_oddIndex() {
        // Proof for v1 (index 1): need v0
        let v0 = Data(SHA256.hash(data: "vote0".data(using: .utf8)!))
        let v1 = Data(SHA256.hash(data: "vote1".data(using: .utf8)!))

        let hash01 = Data(SHA256.hash(data: v0 + v1))

        let proof = [v0.base64EncodedString()]

        let isValid = CryptoManager.verifyMerkleProof(
            voteHash: v1.base64EncodedString(),
            proof: proof,
            root: hash01.base64EncodedString(),
            index: 1
        )

        XCTAssertTrue(isValid, "Proof for odd index should verify")
    }
}
