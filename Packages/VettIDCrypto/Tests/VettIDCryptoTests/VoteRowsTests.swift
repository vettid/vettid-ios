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

    @Test func aChoiceIdTheVaultWouldRefuseIsNotARow() throws {
        func ballot(_ choice: String) throws -> JsonObject {
            try StrictJson.parseObject(
                JsonBuilder().base64("vk", rep(1, 32)).string("choice_id", choice).base64("ballot_sig", rep(2, 64)).build()
            )
        }
        #expect(throws: Never.self) { try VoteRows.leaf(tag: rep(0, 32), ballot: try ballot("abstain-2")) }
        for bad in ["", "Yes", "yes!", "y\u{0301}", String(repeating: "a", count: 33)] {
            #expect(throws: ResultsProblem("rows")) { try VoteRows.leaf(tag: rep(0, 32), ballot: try ballot(bad)) }
        }
    }

    @Test func theRowSaysNothingOfItsBallotInALogLine() throws {
        let results = Array(try docs.str("results").utf8)
        let rowsBytes = Array(try docs.str("rows").utf8)
        let own = try VoteRows.ownRow(results: results, rows: rowsBytes, recordTag: try rows()[0].base64("record_tag", 32))
        #expect("\(own)" == "OwnRow(0 of 3)")
        #expect(!String(reflecting: own).contains("choice"))
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

    /// [o] with the members of [over] replaced by these raw values, in place (the others as they were).
    private func rebuild(_ o: JsonObject, _ over: [String: String]) -> String {
        "{" + o.members.map { JsonBuilder.quote($0.name) + ":" + (over[$0.name] ?? $0.value.raw) }.joined(separator: ",") + "}"
    }

    /// The vector's results, with [over] replaced, and `rows_hash` and (unless [over] names it) `rows_root` made [rows]'s,
    /// so that the check under test is the one that fails.
    private func results(_ over: [String: String] = [:], rows rowsBytes: [UInt8]) throws -> [UInt8] {
        var all = over
        all["rows_hash"] = JsonBuilder.quote(Base64s.encodeStd(Bytes.sha256(rowsBytes)))
        if all["rows_root"] == nil {
            let leaves = try StrictJson.parseObject(rowsBytes).array("rows").map { e -> [UInt8] in
                let row = try e.asObject()
                let tag = try row.base64("record_tag", 32)
                if case .object(let b)? = row["ballot"] { return try VoteRows.leaf(tag: tag, ballot: b) }
                return tag
            }
            all["rows_root"] = JsonBuilder.quote(Base64s.encodeStd(VoteMerkle.root(leaves)))
        }
        return Array(rebuild(try StrictJson.parseObject(docs.str("results")), all).utf8)
    }

    /// The vector's results with its proposal's members [over] replaced.
    private func results(proposal over: [String: String], rows rowsBytes: [UInt8]) throws -> [UInt8] {
        let base = try StrictJson.parseObject(docs.str("results"))
        let p = try base.obj("proposal")
        let doc = try StrictJson.parseObject(p.base64("doc"))
        let changed = Array(rebuild(doc, over).utf8)
        let proposal = rebuild(p, ["doc": JsonBuilder.quote(Base64s.encodeStd(changed))])
        return try results(["proposal": proposal], rows: rowsBytes)
    }

    private func rowsDoc(_ r: [JsonObject]) throws -> [UInt8] {
        Array(rebuild(try StrictJson.parseObject(docs.str("rows")), ["rows": JsonBuilder.array(r.map(\.raw))]).utf8)
    }

    /// Rows whose hash matches but that are out of order, too few, or not the tree of `rows_root`.
    @Test func rowsWithTheRightHashButTheWrongTreeAreAProblem() throws {
        let all = try rows()
        let rowsBytes = try rowsDoc(all)
        let tag = try all[0].base64("record_tag", 32)
        let swapped = try rowsDoc([all[1], all[0], all[2]])
        #expect(throws: ResultsProblem("rows_order")) {
            try VoteRows.ownRow(results: try results(rows: swapped), rows: swapped, recordTag: tag)
        }
        let twice = try rowsDoc([all[0], all[0], all[2]])
        #expect(throws: ResultsProblem("rows_order")) {
            try VoteRows.ownRow(results: try results(rows: twice), rows: twice, recordTag: tag)
        }
        let two = try rowsDoc([all[0], all[1]])
        #expect(throws: ResultsProblem("rows_count")) {
            try VoteRows.ownRow(results: try results(rows: two), rows: two, recordTag: tag)
        }
        let otherRoot = JsonBuilder.quote(Base64s.encodeStd(rep(1, 32)))
        #expect(throws: ResultsProblem("rows_root")) {
            try VoteRows.ownRow(results: try results(["rows_root": otherRoot], rows: rowsBytes), rows: rowsBytes, recordTag: tag)
        }
    }

    // MARK: The observer's check (BALLOT-PROTOCOL §8.4 items 2 to 4)

    /// The ballot vector's signature verifies under the app's label and message (§5), and every §2 case of the Ed25519
    /// vectors is accepted or refused as the vector says.
    @Test func ballotSignaturesFollowTheStrictRules() throws {
        #expect(Ed25519.verify(try v.hex("vk"), label: VoteRows.ballotLabel, try v.hex("ballot_msg"), try v.hex("ballot_sig")))
        let cases = try v.o.array("ed25519")
        #expect(cases.count == 12)
        for c in cases {
            let e = try c.asObject()
            let ok = Ed25519.verify(
                try Bytes.unhex(e.string("key")), label: VoteRows.ballotLabel, try Bytes.unhex(e.string("msg")),
                try Bytes.unhex(e.string("sig"))
            )
            let valid = try e.bool("valid")
            let name = try e.string("case")
            #expect(ok == valid, "\(name)")
        }
    }

    @Test func aTallyOrCountThatTheRowsDoNotMakeIsAProblem() throws {
        let rowsBytes = Array(try docs.str("rows").utf8)
        let tag = try rows()[0].base64("record_tag", 32)
        #expect(throws: Never.self) { try VoteRows.ownRow(results: try results(rows: rowsBytes), rows: rowsBytes, recordTag: tag) }
        let counts = #"{"ballots":2,"eligible":3,"removed":1,"unhandled":0}"#
        let cases: [(String, [String: String])] = [
            ("tally", ["tally": #"{"abstain":0,"no":0,"yes":2}"#]),
            ("tally", ["tally": #"{"abstain":1,"no":1,"yes":1}"#]),
            ("tally", ["tally": #"{"no":1,"yes":1}"#]),
            ("tally", ["tally": #"{"abstain":0,"maybe":0,"no":1,"yes":1}"#]),
            ("ballots", ["counts": counts.replacingOccurrences(of: #""ballots":2"#, with: #""ballots":1"#)]),
            ("ballots", ["counts": counts.replacingOccurrences(of: #""ballots":2"#, with: #""ballots":3"#)]),
            ("results", ["tally": #"{"abstain":0,"no":"1","yes":1}"#]),
        ]
        for (problem, over) in cases {
            #expect(throws: ResultsProblem(problem), "\(over)") {
                try VoteRows.ownRow(results: try results(over, rows: rowsBytes), rows: rowsBytes, recordTag: tag)
            }
        }
    }

    @Test func tagsThatAreNotTheProposalsElectorateAreAProblem() throws {
        let rowsBytes = Array(try docs.str("rows").utf8)
        let tag = try rows()[0].base64("record_tag", 32)
        let otherRoot = JsonBuilder.quote(Base64s.encodeStd(rep(9, 32)))
        #expect(throws: ResultsProblem("record_root")) {
            let changed = try results(proposal: ["record_root": otherRoot], rows: rowsBytes)
            return try VoteRows.ownRow(results: changed, rows: rowsBytes, recordTag: tag)
        }
        #expect(throws: ResultsProblem("results")) {
            try VoteRows.ownRow(results: try results(proposal: ["eligible": "4"], rows: rowsBytes), rows: rowsBytes, recordTag: tag)
        }
    }

    /// A ballot whose signature does not hold, or that was signed for another proposal, or whose choice is not one of
    /// the proposal's.
    @Test func aBallotThatDoesNotVerifyIsAProblem() throws {
        let all = try rows()
        let tag = try all[0].base64("record_tag", 32)
        let at = try #require(all.firstIndex { if case .object? = $0["ballot"] { true } else { false } })
        let ballot = try all[at].obj("ballot")
        func with(_ over: [String: String]) throws -> [UInt8] {
            var changed = all
            changed[at] = try StrictJson.parseObject(rebuild(all[at], ["ballot": rebuild(ballot, over)]))
            return try rowsDoc(changed)
        }
        var sig = try ballot.base64("ballot_sig", 64)
        sig[10] ^= 1
        let badSig = try with(["ballot_sig": JsonBuilder.quote(Base64s.encodeStd(sig))])
        #expect(throws: ResultsProblem("ballot_sig")) {
            try VoteRows.ownRow(results: try results(rows: badSig), rows: badSig, recordTag: tag)
        }
        let otherChoice = try ballot.string("choice_id") == "yes" ? "no" : "yes"
        let moved = try with(["choice_id": JsonBuilder.quote(otherChoice)])
        #expect(throws: ResultsProblem("ballot_sig")) {
            try VoteRows.ownRow(results: try results(rows: moved), rows: moved, recordTag: tag)
        }
        let unknown = try with(["choice_id": JsonBuilder.quote("maybe")])
        #expect(throws: ResultsProblem("rows_choice")) {
            try VoteRows.ownRow(results: try results(rows: unknown), rows: unknown, recordTag: tag)
        }
        // Another proposal (its hash in every ballot_msg): the same rows no longer verify.
        let rowsBytes = try rowsDoc(all)
        #expect(throws: ResultsProblem("ballot_sig")) {
            let changed = try results(proposal: ["title": JsonBuilder.quote("Another")], rows: rowsBytes)
            return try VoteRows.ownRow(results: changed, rows: rowsBytes, recordTag: tag)
        }
    }

    /// A proposal whose choices repeat an id or carry one the vault would refuse is no proposal to count against.
    @Test func aProposalWithBadChoicesIsAProblem() throws {
        let rowsBytes = Array(try docs.str("rows").utf8)
        let tag = try rows()[0].base64("record_tag", 32)
        for choices in [
            #"[{"id":"yes","label":"Yes"},{"id":"yes","label":"No"},{"id":"abstain","label":"Abstain"}]"#,
            #"[{"id":"Yes","label":"Yes"},{"id":"no","label":"No"},{"id":"abstain","label":"Abstain"}]"#,
        ] {
            #expect(throws: ResultsProblem("results"), "\(choices)") {
                let changed = try results(proposal: ["choices": choices], rows: rowsBytes)
                return try VoteRows.ownRow(results: changed, rows: rowsBytes, recordTag: tag)
            }
        }
    }

    /// §8.5: a row without its `ballot`, or a row or ballot with a member the schema does not have, is refused.
    @Test func rowsWithMissingOrUnknownMembersAreAProblem() throws {
        let all = try rows()
        let tag = try all[0].base64("record_tag", 32)
        let at = try #require(all.firstIndex { if case .object? = $0["ballot"] { true } else { false } })
        let empty = try #require(all.firstIndex { if case .null? = $0["ballot"] { true } else { false } })
        let ballot = try all[at].obj("ballot")
        let variants: [String] = [
            "{" + JsonBuilder.quote("record_tag") + ":" + (all[empty]["record_tag"]?.raw ?? "") + "}",
            rebuild(all[empty], [:]).dropLast() + #","note":1}"#,
            rebuild(all[at], ["ballot": String(rebuild(ballot, [:]).dropLast()) + #","note":1}"#]),
        ]
        for (i, variant) in variants.enumerated() {
            var changed = all
            changed[i == 0 || i == 1 ? empty : at] = try StrictJson.parseObject(variant)
            let bytes = try rowsDoc(changed)
            #expect(throws: ResultsProblem("rows"), "\(variant)") {
                try VoteRows.ownRow(results: try results(rows: bytes), rows: bytes, recordTag: tag)
            }
        }
    }

    /// A tree that is not the published one fails before any ballot's signature is checked.
    @Test func theTreeIsCheckedBeforeTheSignatures() throws {
        let all = try rows()
        let tag = try all[0].base64("record_tag", 32)
        let at = try #require(all.firstIndex { if case .object? = $0["ballot"] { true } else { false } })
        var sig = try all[at].obj("ballot").base64("ballot_sig", 64)
        sig[0] ^= 1
        var changed = all
        changed[at] = try StrictJson.parseObject(
            rebuild(all[at], ["ballot": rebuild(try all[at].obj("ballot"), ["ballot_sig": JsonBuilder.quote(Base64s.encodeStd(sig))])])
        )
        let bytes = try rowsDoc(changed)
        let otherRoot = JsonBuilder.quote(Base64s.encodeStd(rep(1, 32)))
        #expect(throws: ResultsProblem("rows_root")) {
            try VoteRows.ownRow(results: try results(["rows_root": otherRoot], rows: bytes), rows: bytes, recordTag: tag)
        }
    }
}
