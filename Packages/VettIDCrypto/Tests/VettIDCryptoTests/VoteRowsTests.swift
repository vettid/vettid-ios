import Foundation
import Testing
@testable import VettIDCrypto

/// The vote's Merkle tree and the member's row of the published results (BALLOT-PROTOCOL §8.2) against vettid-vault's
/// `testdata/vote/vectors.json` (`vote.json`, see SOURCE.md), byte for byte. Mirrors vettid-android `VoteRowsTest`.
struct VoteRowsTests {
    private let v: VectorDoc
    private let docs: VectorDoc

    init() throws {
        v = try VectorDoc.load("vote.json")
        docs = try v.sub("documents")
    }

    @Test func rootsAndProofsMatchTheVectors() throws {
        for c in try v.o.array("merkle") {
            let m = try c.asObject()
            let leaves = try m.array("leaves").map { try Bytes.unhex($0.asString()) }
            let root = try Bytes.unhex(m.string("root"))
            #expect(VoteMerkle.root(leaves) == root, "root of \(leaves.count)")
            for (i, p) in (try m.optArray("proofs") ?? []).enumerated() {
                guard case .array(_, let items) = p else { Issue.record("proof \(i) is not an array"); continue }
                let want = try items.map { try Bytes.unhex($0.asString()) }
                let got = try #require(VoteMerkle.proof(leaves, i))
                #expect(got == want, "proof \(i)")
                #expect(VoteMerkle.verify(root: root, leaf: leaves[i], index: UInt64(i), size: UInt64(leaves.count), path: got))
            }
        }
    }

    @Test func theBallotLeafMatchesTheVector() throws {
        let ballot = try StrictJson.parseObject(
            JsonBuilder()
                .base64("vk", v.hex("vk"))
                .string("choice_id", v.str("choice_id"))
                .base64("ballot_sig", v.hex("ballot_sig"))
                .build()
        )
        #expect(try VoteRows.leaf(tag: v.hex("record_tag"), ballot: ballot) == v.hex("ballot_leaf"))
    }

    @Test func aProofForAnotherLeafOrSizeFails() throws {
        let leaves = (0..<5).map { [UInt8($0)] }
        let root = VoteMerkle.root(leaves)
        let p = try #require(VoteMerkle.proof(leaves, 2))
        #expect(VoteMerkle.verify(root: root, leaf: leaves[2], index: 2, size: 5, path: p))
        #expect(!VoteMerkle.verify(root: root, leaf: leaves[3], index: 2, size: 5, path: p))
        #expect(!VoteMerkle.verify(root: root, leaf: leaves[2], index: 3, size: 5, path: p))
        #expect(!VoteMerkle.verify(root: root, leaf: leaves[2], index: 2, size: 5, path: Array(p.dropLast())))
        #expect(!VoteMerkle.verify(root: root, leaf: leaves[2], index: 5, size: 5, path: p))
        #expect(!VoteMerkle.verify(root: root, leaf: leaves[2], index: 2, size: 5, path: p + [rep(0, 31)]))
        #expect(VoteMerkle.proof(leaves, 5) == nil)
        #expect(VoteMerkle.proof(leaves, -1) == nil)
    }

    private func rows() throws -> [JsonObject] {
        try StrictJson.parseObject(docs.str("rows")).array("rows").map { try $0.asObject() }
    }

    @Test func everyMembersRowIsFoundWithAProofTheVaultAccepts() throws {
        let results = Array(try docs.str("results").utf8)
        let rowsBytes = Array(try docs.str("rows").utf8)
        let root = try StrictJson.parseObject(results).base64("rows_root", 32)
        let all = try rows()
        let leaves = try all.map { row -> [UInt8] in
            let tag = try row.base64("record_tag", 32)
            if case .object(let b)? = row["ballot"] { return try VoteRows.leaf(tag: tag, ballot: b) }
            return tag
        }
        for (i, row) in all.enumerated() {
            let own = try VoteRows.ownRow(results: results, rows: rowsBytes, recordTag: row.base64("record_tag", 32))
            #expect(own.index == UInt64(i))
            #expect(own.treeSize == 3)
            if case .object? = row["ballot"] { #expect(own.ballot != nil) } else { #expect(own.ballot == nil) }
            #expect(VoteMerkle.verify(root: root, leaf: leaves[i], index: own.index, size: own.treeSize, path: own.path))
        }
    }

    @Test func anUnknownTagHasNoRow() throws {
        let results = Array(try docs.str("results").utf8)
        let rowsBytes = Array(try docs.str("rows").utf8)
        #expect(throws: ResultsProblem("no_row")) {
            try VoteRows.ownRow(results: results, rows: rowsBytes, recordTag: rep(7, 32))
        }
    }

    @Test func rowsThatAreNotWhatTheResultsNameAreAProblem() throws {
        let results = Array(try docs.str("results").utf8)
        let rowsBytes = Array(try docs.str("rows").utf8)
        let tag = try v.hex("record_tag")
        var changed = rowsBytes
        changed[changed.count / 2] &+= 1
        #expect(throws: ResultsProblem("rows_hash")) { try VoteRows.ownRow(results: results, rows: changed, recordTag: tag) }
        #expect(throws: ResultsProblem("results")) { try VoteRows.ownRow(results: Array("{}".utf8), rows: rowsBytes, recordTag: tag) }
        #expect(throws: ResultsProblem("results")) { try VoteRows.ownRow(results: Array("nope".utf8), rows: rowsBytes, recordTag: tag) }
    }

    /// Rows whose hash matches but that are out of order, too few, or not the tree of `rows_root`.
    @Test func rowsWithTheRightHashButTheWrongTreeAreAProblem() throws {
        let rowsBytes = Array(try docs.str("rows").utf8)
        let base = try StrictJson.parseObject(docs.str("results"))
        let all = try rows()
        func results(rows: [UInt8], eligible: UInt64, root: [UInt8]? = nil) throws -> [UInt8] {
            JsonBuilder()
                .base64("rows_hash", Bytes.sha256(rows))
                .base64("rows_root", try root ?? base.base64("rows_root", 32))
                .raw("counts", JsonBuilder().uint("eligible", eligible).build())
                .bytes()
        }
        func rowsDoc(_ r: [JsonObject]) -> [UInt8] {
            Array(JsonBuilder().raw("rows", JsonBuilder.array(r.map(\.raw))).build().utf8)
        }
        let tag = try all[0].base64("record_tag", 32)
        let swapped = rowsDoc([all[1], all[0], all[2]])
        #expect(throws: ResultsProblem("rows_order")) { try VoteRows.ownRow(results: try results(rows: swapped, eligible: 3), rows: swapped, recordTag: tag) }
        let twice = rowsDoc([all[0], all[0], all[2]])
        #expect(throws: ResultsProblem("rows_order")) { try VoteRows.ownRow(results: try results(rows: twice, eligible: 3), rows: twice, recordTag: tag) }
        #expect(throws: ResultsProblem("rows_count")) { try VoteRows.ownRow(results: try results(rows: rowsBytes, eligible: 2), rows: rowsBytes, recordTag: tag) }
        #expect(throws: ResultsProblem("rows_root")) {
            try VoteRows.ownRow(results: try results(rows: rowsBytes, eligible: 3, root: rep(1, 32)), rows: rowsBytes, recordTag: tag)
        }
    }
}
