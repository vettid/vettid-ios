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
            if case .object(let b)? = row["ballot"] {
                // The loose leaf the tests' tree helper uses is the strict one for every valid row.
                #expect(try VoteRows.looseLeaf(tag: tag, ballot: b) == VoteRows.leaf(tag: tag, ballot: b))
                return try VoteRows.leaf(tag: tag, ballot: b)
            }
            return tag
        }
        for (i, row) in all.enumerated() {
            let checked = try VoteRows.ownRow(results: results, rows: rowsBytes, recordTag: row.base64("record_tag", 32))
            #expect(checked.problem == nil)
            let own = checked.own
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
        let own = try VoteRows.ownRow(results: results, rows: rowsBytes, recordTag: try rows()[0].base64("record_tag", 32)).own
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

    /// Rows whose hash is not the published `rows_hash` but that make the published tree: the member's row is still had.
    /// Results that don't parse have none.
    @Test func rowsThatAreNotWhatTheResultsNameAreAProblem() throws {
        let rowsBytes = Array(try docs.str("rows").utf8)
        let tag = try v.hex("record_tag")
        let otherHash = JsonBuilder.quote(Base64s.encodeStd(rep(3, 32)))
        #expect(try observed(try results(["rows_hash": otherHash], rows: rowsBytes), rowsBytes) == ResultsProblem("rows_hash"))
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
        if all["rows_hash"] == nil { all["rows_hash"] = JsonBuilder.quote(Base64s.encodeStd(Bytes.sha256(rowsBytes))) }
        if all["rows_root"] == nil {
            all["rows_root"] = JsonBuilder.quote(Base64s.encodeStd(VoteMerkle.root(try leaves(rowsBytes))))
        }
        return Array(rebuild(try StrictJson.parseObject(docs.str("results")), all).utf8)
    }

    /// The leaves of [rowsBytes]' tree.
    private func leaves(_ rowsBytes: [UInt8]) throws -> [[UInt8]] {
        try StrictJson.parseObject(rowsBytes).array("rows").map { e -> [UInt8] in
            let row = try e.asObject()
            let tag = try row.base64("record_tag", 32)
            if case .object(let b)? = row["ballot"] { return try VoteRows.looseLeaf(tag: tag, ballot: b) }
            return tag
        }
    }

    /// What the rest of the observer's check finds in [resultsBytes] and [rowsBytes], once it has returned the row of
    /// the last tag with a proof to the published `rows_root`: the member's row is still had, and submitted.
    private func observed(_ resultsBytes: [UInt8], _ rowsBytes: [UInt8]) throws -> ResultsProblem? {
        let items = try StrictJson.parseObject(rowsBytes).array("rows")
        let last = items.count - 1
        let tag = try items[last].asObject().base64("record_tag", 32)
        let checked = try VoteRows.ownRow(results: resultsBytes, rows: rowsBytes, recordTag: tag)
        let root = try StrictJson.parseObject(resultsBytes).base64("rows_root", 32)
        let all = try leaves(rowsBytes)
        let own = checked.own
        #expect(own.index == UInt64(last) && own.treeSize == UInt64(all.count))
        #expect(VoteMerkle.verify(root: root, leaf: all[last], index: own.index, size: own.treeSize, path: own.path))
        return checked.problem
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

    /// Rows out of order or repeated still make the published tree when it was made over them: the member's row is had
    /// with the problem. Too few rows (a tree whose size is not `counts.eligible`), or not the tree of `rows_root`, give
    /// no row.
    @Test func rowsWithTheRightHashButTheWrongTreeAreAProblem() throws {
        let all = try rows()
        let rowsBytes = try rowsDoc(all)
        let tag = try all[0].base64("record_tag", 32)
        let swapped = try rowsDoc([all[1], all[0], all[2]])
        #expect(try observed(try results(rows: swapped), swapped) == ResultsProblem("rows_order"))
        let twice = try rowsDoc([all[0], all[0], all[2]])
        #expect(try observed(try results(rows: twice), twice) == ResultsProblem("rows_order"))
        let two = try rowsDoc([all[0], all[1]])
        #expect(throws: ResultsProblem("rows_count")) {
            try VoteRows.ownRow(results: try results(rows: two), rows: two, recordTag: tag)
        }
        let otherRoot = JsonBuilder.quote(Base64s.encodeStd(rep(1, 32)))
        #expect(throws: ResultsProblem("rows_root")) {
            try VoteRows.ownRow(results: try results(["rows_root": otherRoot], rows: rowsBytes), rows: rowsBytes, recordTag: tag)
        }
    }

    /// Rows of the longest ids the vault takes (a 32-character `choice_id`), every member having voted, written compactly
    /// or indented: within the bound.
    @Test func theLongestRowsAtFullTurnoutAreWithinTheBound() throws {
        let n = 1_000
        let choice = "approve-budget-2027-and-the-plan"
        #expect(choice.utf8.count == 32)
        let tags = (0..<n).map { Bytes.sha256(Array("tag \($0)".utf8)) }.sorted { $0.lexicographicallyPrecedes($1) }
        let (sig, vk) = (Base64s.encodeStd(rep(2, 64)), Base64s.encodeStd(rep(1, 32)))
        let compact = tags.map { tag in
            #"{"ballot":{"ballot_sig":"\#(sig)","choice_id":"\#(choice)","vk":"\#(vk)"},"record_tag":"\#(Base64s.encodeStd(tag))"}"#
        }
        #expect(compact.allSatisfy { $0.utf8.count + 1 == VoteRows.longestRow })
        let indented = tags.map { tag in
            "\n    {\n      \"ballot\": {\n        \"ballot_sig\": \"\(sig)\",\n        \"choice_id\": \"\(choice)\",\n"
                + "        \"vk\": \"\(vk)\"\n      },\n      \"record_tag\": \"\(Base64s.encodeStd(tag))\"\n    }"
        }
        let base = try StrictJson.parseObject(docs.str("rows"))
        let counts = #"{"ballots":\#(n),"eligible":\#(n),"removed":0,"unhandled":0}"#
        for rowsJson in [compact, indented] {
            let bytes = Array(rebuild(base, ["rows": "[" + rowsJson.joined(separator: ",") + "\n  ]"]).utf8)
            #expect(bytes.count > n * 256 + 4_096, "over the former bound")
            #expect(bytes.count <= n * VoteRows.rowBytes + VoteRows.rowsOverhead)
            let published = try results(["counts": counts], rows: bytes)
            let checked = try VoteRows.ownRow(results: published, rows: bytes, recordTag: tags[0])
            #expect(checked.own.index == 0 && checked.own.treeSize == UInt64(n))
        }
    }

    /// The cap on reading `rows.json` is that of the results' `counts.eligible`, and the global one when they don't say.
    @Test func theRowsCapIsTheResultsElectorates() throws {
        let results = Array(try docs.str("results").utf8)
        #expect(VoteRows.rowsCap(results: results) == 3 * VoteRows.rowBytes + VoteRows.rowsOverhead)
        #expect(VoteRows.rowsCap(results: Array("nope".utf8)) == VoteRows.rowsMax)
    }

    /// The member's tag on two rows: the rows' order is the problem, and the first of them is the row, with its proof.
    @Test func aTagOnTwoRowsGivesTheFirst() throws {
        let all = try rows()
        let changed = try rowsDoc([all[0], all[1], all[1]])
        let tag = try all[1].base64("record_tag", 32)
        let checked = try VoteRows.ownRow(results: try results(rows: changed), rows: changed, recordTag: tag)
        #expect(checked.problem == ResultsProblem("rows_order"))
        #expect(checked.own.index == 1 && checked.own.treeSize == 3)
        let root = try VoteMerkle.root(leaves(changed))
        #expect(VoteMerkle.verify(root: root, leaf: try leaves(changed)[1], index: 1, size: 3, path: checked.own.path))
    }

    /// What the member's row needs of `results.json` (`rows_root`, `counts.eligible`): without it there is nothing to
    /// submit. Without `rows_hash` the row is still had.
    @Test func resultsWithoutWhatTheRowNeedsAreAProblemWithNoRow() throws {
        let rowsBytes = Array(try docs.str("rows").utf8)
        let tag = try rows()[0].base64("record_tag", 32)
        let base = try StrictJson.parseObject(try results(rows: rowsBytes))
        func without(_ name: String) -> [UInt8] {
            Array(("{" + base.members.filter { $0.name != name }.map { JsonBuilder.quote($0.name) + ":" + $0.value.raw }
                .joined(separator: ",") + "}").utf8)
        }
        for name in ["rows_root", "counts"] {
            #expect(throws: ResultsProblem("results"), "\(name)") {
                try VoteRows.ownRow(results: without(name), rows: rowsBytes, recordTag: tag)
            }
        }
        let noEligible = #"{"ballots":2,"removed":1,"unhandled":0}"#
        #expect(throws: ResultsProblem("results")) {
            try VoteRows.ownRow(results: try results(["counts": noEligible], rows: rowsBytes), rows: rowsBytes, recordTag: tag)
        }
        #expect(try observed(without("rows_hash"), rowsBytes) == ResultsProblem("results"))
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

    /// The member's row still holds, so it is returned with the problem (and submitted).
    @Test func aTallyOrCountThatTheRowsDoNotMakeIsAProblemWithTheRowStillHad() throws {
        let rowsBytes = Array(try docs.str("rows").utf8)
        #expect(try observed(try results(rows: rowsBytes), rowsBytes) == nil)
        let counts = #"{"ballots":2,"eligible":3,"removed":1,"unhandled":0}"#
        let cases: [(String, [String: String])] = [
            ("tally", ["tally": #"{"abstain":0,"no":0,"yes":2}"#]),
            ("tally", ["tally": #"{"abstain":1,"no":1,"yes":1}"#]),
            ("tally", ["tally": #"{"no":1,"yes":1}"#]),
            ("tally", ["tally": #"{"abstain":0,"maybe":0,"no":1,"yes":1}"#]),
            ("ballots", ["counts": counts.replacingOccurrences(of: #""ballots":2"#, with: #""ballots":1"#)]),
            ("ballots", ["counts": counts.replacingOccurrences(of: #""ballots":2"#, with: #""ballots":3"#)]),
            ("results", ["tally": #"{"abstain":0,"no":"1","yes":1}"#]),
            ("results", ["tally": "[]"]),
            ("results", ["counts": counts.replacingOccurrences(of: #""ballots":2"#, with: #""ballots":"2""#)]),
            ("results", ["proposal": #"{"doc":"bm9wZQ==","sig":""}"#]),
        ]
        for (problem, over) in cases {
            #expect(try observed(try results(over, rows: rowsBytes), rowsBytes) == ResultsProblem(problem), "\(over)")
        }
    }

    @Test func tagsThatAreNotTheProposalsElectorateAreAProblemWithTheRowStillHad() throws {
        let rowsBytes = Array(try docs.str("rows").utf8)
        let otherRoot = JsonBuilder.quote(Base64s.encodeStd(rep(9, 32)))
        let otherElectorate = try results(proposal: ["record_root": otherRoot], rows: rowsBytes)
        #expect(try observed(otherElectorate, rowsBytes) == ResultsProblem("record_root"))
        #expect(try observed(try results(proposal: ["eligible": "4"], rows: rowsBytes), rowsBytes) == ResultsProblem("results"))
    }

    /// A ballot whose signature does not hold, or that was signed for another proposal, or whose choice is not one of
    /// the proposal's: the member's row is still had.
    @Test func aBallotThatDoesNotVerifyIsAProblemWithTheRowStillHad() throws {
        let all = try rows()
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
        #expect(try observed(try results(rows: badSig), badSig) == ResultsProblem("ballot_sig"))
        let otherChoice = try ballot.string("choice_id") == "yes" ? "no" : "yes"
        let moved = try with(["choice_id": JsonBuilder.quote(otherChoice)])
        #expect(try observed(try results(rows: moved), moved) == ResultsProblem("ballot_sig"))
        let unknown = try with(["choice_id": JsonBuilder.quote("maybe")])
        #expect(try observed(try results(rows: unknown), unknown) == ResultsProblem("rows_choice"))
        // Another proposal (its hash in every ballot_msg): the same rows no longer verify.
        let rowsBytes = try rowsDoc(all)
        let changed = try results(proposal: ["title": JsonBuilder.quote("Another")], rows: rowsBytes)
        #expect(try observed(changed, rowsBytes) == ResultsProblem("ballot_sig"))
    }

    /// A proposal whose choices repeat an id or carry one the vault would refuse is no proposal to count against.
    @Test func aProposalWithBadChoicesIsAProblemWithTheRowStillHad() throws {
        let rowsBytes = Array(try docs.str("rows").utf8)
        for choices in [
            #"[{"id":"yes","label":"Yes"},{"id":"yes","label":"No"},{"id":"abstain","label":"Abstain"}]"#,
            #"[{"id":"Yes","label":"Yes"},{"id":"no","label":"No"},{"id":"abstain","label":"Abstain"}]"#,
        ] {
            let changed = try results(proposal: ["choices": choices], rows: rowsBytes)
            #expect(try observed(changed, rowsBytes) == ResultsProblem("results"), "\(choices)")
        }
    }

    /// §8.5: a row without its `ballot`, a row or ballot with a member the schema does not have, or a ballot the vault
    /// would not read, is a problem, but still a leaf of the published tree: the member's row is had. A ballot that is no
    /// leaf at all (a member that is no base64 or string) gives no tree, and no row.
    @Test func rowsWithMissingOrUnknownMembersAreAProblem() throws {
        let all = try rows()
        let tag = try all[0].base64("record_tag", 32)
        let at = try #require(all.firstIndex { if case .object? = $0["ballot"] { true } else { false } })
        let empty = try #require(all.firstIndex { if case .null? = $0["ballot"] { true } else { false } })
        let ballot = try all[at].obj("ballot")
        let variants: [(Int, String)] = [
            (empty, "{" + JsonBuilder.quote("record_tag") + ":" + (all[empty]["record_tag"]?.raw ?? "") + "}"),
            (empty, rebuild(all[empty], [:]).dropLast() + #","note":1}"#),
            (at, rebuild(all[at], ["ballot": String(rebuild(ballot, [:]).dropLast()) + #","note":1}"#])),
            (at, rebuild(all[at], ["ballot": rebuild(ballot, ["vk": JsonBuilder.quote(Base64s.encodeStd(rep(1, 31)))])])),
            (at, rebuild(all[at], ["ballot": rebuild(ballot, ["choice_id": JsonBuilder.quote("Yes")])])),
        ]
        for (i, variant) in variants {
            var changed = all
            changed[i] = try StrictJson.parseObject(variant)
            let bytes = try rowsDoc(changed)
            #expect(try observed(try results(rows: bytes), bytes) == ResultsProblem("rows"), "\(variant)")
        }
        for over in [["choice_id": "7"], ["vk": JsonBuilder.quote("not base64!")]] {
            var changed = all
            changed[at] = try StrictJson.parseObject(rebuild(all[at], ["ballot": rebuild(ballot, over)]))
            let bytes = try rowsDoc(changed)
            // The published root kept as it was: the check must not make a leaf of the bad row itself.
            let published = try results(["rows_root": JsonBuilder.quote(Base64s.encodeStd(rep(1, 32)))], rows: bytes)
            #expect(throws: ResultsProblem("rows"), "\(over)") {
                try VoteRows.ownRow(results: published, rows: bytes, recordTag: tag)
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

    /// §8.5: `rows.json` is exactly `v` 1, the results' `proposal_id` and `rows`, and the results are of the proposal they
    /// carry: neither is one of the vault's four inputs (VAULT-MESSAGING 0.83.2 §10.19.6 step 1), so the member's row is
    /// still had. Nested deeper than a ballot, there is no tree and no row.
    @Test func rowsOrResultsOfAnotherProposalOrShapeAreAProblem() throws {
        let base = try StrictJson.parseObject(docs.str("rows"))
        let tag = try rows()[0].base64("record_tag", 32)
        let variants = [
            rebuild(base, ["v": "2"]),
            rebuild(base, ["proposal_id": JsonBuilder.quote("01JBQZ0000000000000000000B")]),
            String(rebuild(base, [:]).dropLast()) + #","note":1}"#,
            "{" + JsonBuilder.quote("rows") + ":" + (base["rows"]?.raw ?? "") + "}",
        ]
        for variant in variants {
            let bytes = Array(variant.utf8)
            #expect(try observed(try results(rows: bytes), bytes) == ResultsProblem("rows"), "\(variant)")
        }
        let deep = Array(rebuild(base, ["rows": #"[{"record_tag":"AA==","ballot":{"vk":{"x":{"y":1}}}}]"#]).utf8)
        let anyRoot = ["rows_root": JsonBuilder.quote(Base64s.encodeStd(rep(1, 32)))]
        #expect(throws: ResultsProblem("rows")) {
            try VoteRows.ownRow(results: try results(anyRoot, rows: deep), rows: deep, recordTag: tag)
        }
        let rowsBytes = Array(try docs.str("rows").utf8)
        let other = JsonBuilder.quote("01JBQZ0000000000000000000B")
        #expect(try observed(try results(["proposal_id": other], rows: rowsBytes), rowsBytes) == ResultsProblem("results"))
    }

    /// A `rows.json` larger than `eligible` rows can be is refused before it is hashed or parsed (the app's own bound):
    /// no row.
    @Test func rowsLargerThanTheElectorateCanMakeAreAProblem() throws {
        let tag = try rows()[0].base64("record_tag", 32)
        let big = Array(try docs.str("rows").utf8) + [UInt8](repeating: 0x20, count: 3 * VoteRows.rowBytes + VoteRows.rowsOverhead)
        let anyRoot = ["rows_root": JsonBuilder.quote(Base64s.encodeStd(rep(1, 32)))]
        #expect(throws: ResultsProblem("rows")) {
            try VoteRows.ownRow(results: try results(anyRoot, rows: big), rows: big, recordTag: tag)
        }
    }
}
