import Foundation

/// A member's row of a vote's published results (BALLOT-PROTOCOL §8.2, §8.5): the row `rows.json` holds under the
/// member's record tag, with its inclusion proof to the results' `rows_root`. [ballot] is the row's `ballot` object as
/// the site has it (`vk`, `choice_id`, `ballot_sig`), or nil for an empty row.
public struct OwnRow: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let ballot: JsonObject?
    public let index: UInt64
    public let treeSize: UInt64
    public let path: [[UInt8]]

    /// Never the row's ballot (its choice) in a log line.
    public var description: String { "OwnRow(\(index) of \(treeSize))" }
    public var debugDescription: String { description }
}

/// Why the site's results could not be taken as they are: said to the member as a problem with the published results.
/// The reason is a fixed word, never input bytes.
public struct ResultsProblem: Error, Equatable, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// The observer's check (BALLOT-PROTOCOL §8.4, items 2 to 4) the app does from the site's bytes before
/// `vote.results.submit` (VAULT-MESSAGING 0.83.2 §10.19.6 step 1), in two parts. The member's row: `results.json` parses
/// (its `rows_root` and `counts.eligible`), `rows.json` gives as many leaves as `eligible`, their tree is `rows_root`, and
/// the member's tag has a row there with its proof; when any of these fails the vault would not take the row (step 3:
/// input that does not verify), so there is nothing to submit (a thrown ``ResultsProblem``). The rest, every other
/// failure of the observer's check: the hash of `rows.json`, the rows' order and schema, the proposal and its choices,
/// `eligible` against the proposal's, the tags' tree against the proposal's `record_root`, every ballot's `ballot_sig`
/// under its `vk` and its choice one of the proposal's (the member's own included), and the tally and `ballots`
/// recomputed; when one of these fails the row is still returned with the problem (``Checked/problem``): it is
/// submitted, the vault judges it, and the member is told the rest of the published results don't add up. The results'
/// signature and bundle, the anchor and the verdict are the vault's; it never relies on this. Builds on vettid-android
/// `VoteRows` (the hash, order and tree), with the signatures, the tally and `record_root` added.
public enum VoteRows {
    /// The most rows read: far above any electorate a vote is held for, and small enough to bound the work on a hostile
    /// `rows.json` (the app reads at most ``rowsMax`` bytes of it).
    public static let maxRows = 100_000

    /// The label of `ballot_sig` (BALLOT-PROTOCOL §5), its `0x00` included (§2).
    public static let ballotLabel = "vettid/vote/1/ballot\u{0}"

    private static let keySize = 32
    private static let sigSize = 64
    private static let maxId = 32

    /// The member's row with its proof, and the first problem the rest of the check found in the published results
    /// (nil when they all hold).
    public struct Checked: Sendable {
        public let own: OwnRow
        /// The next rows under the member's tag, at most ``maxOthers`` (VAULT-MESSAGING 0.83.3 §10.19.6 step 1, sent as
        /// `other_rows`), each with its proof and its ballot as published, whatever its lengths.
        public let others: [OwnRow]
        public let problem: ResultsProblem?
    }

    /// The most `other_rows` entries (§10.19.8: at most 4).
    public static let maxOthers = 4

    /// What the app needs of `results.json` for the member's row.
    private struct Published {
        let rowsRoot: [UInt8]
        let eligible: UInt64
    }

    /// The rest of `results.json` and the proposal it carries, for the observer's check of everything else.
    private struct Observed {
        let ballots: UInt64
        let tally: [String: UInt64]
        let proposalHash: [UInt8]
        let recordRoot: [UInt8]
        let choices: Set<String>
        let proposalID: String
    }

    /// The longest row of a valid `rows.json` written compactly, with the comma after it (BALLOT-PROTOCOL §8.5):
    /// `{"ballot":{"ballot_sig":"…","choice_id":"…","vk":"…"},"record_tag":"…"},` with a 64-byte `ballot_sig`, a
    /// 32-byte `vk` and a 32-byte `record_tag` in standard base64 (88, 44 and 44 characters) and a `choice_id` of at
    /// most 32 characters of `[a-z0-9-]` (VAULT-MESSAGING §10.19.4 step 2), which no JSON escape lengthens: 276 bytes.
    public static let longestRow = 276
    /// The most bytes a row may take in `rows.json`: ``longestRow`` with room for white space (BALLOT-PROTOCOL does not
    /// make `rows.json` JCS, so it may be indented), and the most the rest of it may take. A larger `rows.json` is
    /// refused before it is hashed or parsed: the app's own bound on the work a hostile site can cause, not one of the
    /// vault's inputs (VAULT-MESSAGING 0.83.2 §10.19.6 step 1), so it stops the submit (chosen; not in the spec).
    public static let rowBytes = 512
    public static let rowsOverhead = 4_096
    /// The largest `rows.json` read at all: ``maxRows`` rows.
    public static let rowsMax = maxRows * rowBytes + rowsOverhead

    /// What the results say of how much of `rows.json` to read (§10.19.6 step 1).
    public enum RowsBound: Equatable, Sendable {
        /// The most bytes of `rows.json` to read.
        case cap(Int)
        /// `counts.eligible` is an integer outside 1 to ``maxRows``: `rows.json` cannot be bounded, so the member's row
        /// cannot be had while the vault still judges the results themselves (§10.19.6 steps 2 and 3).
        case outOfRange
        /// `counts.eligible` does not read at all.
        case unreadable
    }

    /// ``RowsBound`` of [bytes], the `results.json` read first.
    public static func rowsBound(results bytes: [UInt8]) -> RowsBound {
        guard let eligible = try? StrictJson.parseObject(bytes).obj("counts").uint("eligible", min: 0, max: StrictJson.maxSafeInteger)
        else { return .unreadable }
        guard (1...UInt64(maxRows)).contains(eligible) else { return .outOfRange }
        return .cap(min(rowsMax, Int(eligible) * rowBytes + rowsOverhead))
    }

    /// One row of `rows.json`: its tag, its ballot (`vk`, `choice_id`, `ballot_sig`) as the site has it or nil, and its
    /// leaf in the rows' tree.
    private struct Row {
        let tag: [UInt8]
        let ballot: JsonObject?
        let leaf: [UInt8]
    }

    /// The rows of `rows.json`, the first problem with their order or schema (which do not stop the tree), and the
    /// `proposal_id` it names (nil when it names none).
    private struct ReadRows {
        let rows: [Row]
        let problem: ResultsProblem?
        let proposalID: String?
    }

    /// Checks [rowsBytes] against [resultsBytes] and returns the row of [recordTag] with its proof, and what the rest of
    /// the check found. Throws ``ResultsProblem`` when the row or its proof cannot be had, a tag that has no row included.
    public static func ownRow(results resultsBytes: [UInt8], rows rowsBytes: [UInt8], recordTag: [UInt8]) throws -> Checked {
        let results = try parse(resultsBytes)
        let published = try read(results)
        // Bounded before anything else is done with them: as many rows as `eligible`, each of at most ``rowBytes``.
        if UInt64(rowsBytes.count) > published.eligible * UInt64(rowBytes) + UInt64(rowsOverhead) { throw ResultsProblem("rows") }
        let read = try readRows(rowsBytes, eligible: published.eligible)
        let rows = read.rows
        // The cheap tree check first: a hostile `rows.json` costs no signature checks unless it is the published tree.
        let leaves = rows.map(\.leaf)
        if !Bytes.constantTimeEquals(VoteMerkle.root(leaves), published.rowsRoot) { throw ResultsProblem("rows_root") }
        // A tag on more than one row is already a problem with the rows' order: the first of them is submitted, and the
        // vault judges it against the index its `record_proof` fixes (VAULT-MESSAGING §10.19.6 step 3; chosen; not in
        // the spec).
        let matches = rows.indices.filter { Bytes.constantTimeEquals(rows[$0].tag, recordTag) }
        guard let found = matches.first else { throw ResultsProblem("no_row") }
        guard let path = VoteMerkle.proof(leaves, found) else { throw ResultsProblem("rows") }
        let own = OwnRow(ballot: rows[found].ballot, index: UInt64(found), treeSize: UInt64(leaves.count), path: path)
        // The next rows under the member's tag (§10.19.6 step 1), for `other_rows`.
        let others = try matches.dropFirst().prefix(maxOthers).map { i -> OwnRow in
            guard let p = VoteMerkle.proof(leaves, i) else { throw ResultsProblem("rows") }
            return OwnRow(ballot: rows[i].ballot, index: UInt64(i), treeSize: UInt64(leaves.count), path: p)
        }
        do {
            try observe(results, rowsBytes, read, eligible: published.eligible)
            return Checked(own: own, others: others, problem: nil)
        } catch let p as ResultsProblem {
            return Checked(own: own, others: others, problem: p)
        }
    }

    /// §8.4 items 2 to 4 beyond the member's row: the proposal, the tags against its `record_root` (the electorate it
    /// fixed before anyone voted, §8.1, §8.2: record leaves in order), every ballot, the tally and `ballots`.
    private static func observe(_ results: JsonObject, _ rowsBytes: [UInt8], _ read: ReadRows, eligible: UInt64) throws {
        let rowsHash: [UInt8]
        do {
            rowsHash = try results.base64("rows_hash", VoteMerkle.hashSize)
        } catch {
            throw ResultsProblem("results")
        }
        if !Bytes.constantTimeEquals(Bytes.sha256(rowsBytes), rowsHash) { throw ResultsProblem("rows_hash") }
        if let p = read.problem { throw p }
        let rows = read.rows
        let observed = try readObserved(results, eligible: eligible)
        // §8.5: the rows are of the proposal the results carry (the vault never reads `rows.json`, so not one of its
        // inputs).
        if read.proposalID != observed.proposalID { throw ResultsProblem("rows") }
        if !Bytes.constantTimeEquals(VoteMerkle.root(rows.map(\.tag)), observed.recordRoot) {
            throw ResultsProblem("record_root")
        }
        try checkTally(rows, observed)
    }

    /// §8.4 items 3 and 4: every ballot verifies and names one of the proposal's choices, and every choice's count and
    /// the number of ballots are the rows', exactly.
    private static func checkTally(_ rows: [Row], _ observed: Observed) throws {
        var counted: [String: UInt64] = [:]
        for row in rows {
            guard let b = row.ballot else { continue }
            counted[try ballotChoice(row.tag, b, observed), default: 0] += 1
        }
        if counted.values.reduce(0, +) != observed.ballots { throw ResultsProblem("ballots") }
        for choice in observed.choices where counted[choice, default: 0] != observed.tally[choice] {
            throw ResultsProblem("tally")
        }
    }

    /// A ballot's choice, once its choice is one of the proposal's and its `ballot_sig` verifies under its `vk` for
    /// `ballot_msg = proposal_hash || record_tag || lp(choice_id)` (§5, §8.4 item 3), by the strict rules of §2.
    private static func ballotChoice(_ tag: [UInt8], _ b: JsonObject, _ p: Observed) throws -> String {
        let vk: [UInt8]
        let sig: [UInt8]
        let choice: String
        do {
            vk = try b.base64("vk", keySize)
            sig = try b.base64("ballot_sig", sigSize)
            choice = try b.string("choice_id")
        } catch {
            throw ResultsProblem("rows")
        }
        guard p.choices.contains(choice) else { throw ResultsProblem("rows_choice") }
        let msg = Bytes.concat(p.proposalHash, tag, lp(Array(choice.utf8)))
        guard Ed25519.verify(vk, label: ballotLabel, msg, sig) else { throw ResultsProblem("ballot_sig") }
        return choice
    }

    /// `results.json` (§8.5) as an object.
    private static func parse(_ bytes: [UInt8]) throws -> JsonObject {
        do {
            return try StrictJson.parseObject(bytes)
        } catch {
            throw ResultsProblem("results")
        }
    }

    /// What the member's row needs of `results.json`: `rows_root` and `counts.eligible`.
    private static func read(_ results: JsonObject) throws -> Published {
        do {
            return Published(
                rowsRoot: try results.base64("rows_root", VoteMerkle.hashSize),
                eligible: try results.obj("counts").uint("eligible", min: 1, max: UInt64(maxRows))
            )
        } catch {
            throw ResultsProblem("results")
        }
    }

    /// The rest of `results.json` (§8.5) and its proposal: `ballots`, the tally, the proposal's hash, its `eligible` (the
    /// results' own), its `record_root` and its choice ids. A tally that names other choices than the proposal's, or not
    /// every one, is a problem.
    private static func readObserved(_ results: JsonObject, eligible: UInt64) throws -> Observed {
        do {
            let ballots = try results.obj("counts").uint("ballots", min: 0, max: eligible)
            let proposalBytes = try results.obj("proposal").base64("doc")
            let proposal = try StrictJson.parseObject(proposalBytes)
            if try proposal.uint("eligible", min: 1, max: UInt64(maxRows)) != eligible { throw ResultsProblem("results") }
            // §8.5: the results are of the proposal they carry. The vault holds its proposal and compares it byte for byte
            // (step 2), so this is the observer's find, not one of the four inputs.
            let proposalID = try proposal.string("proposal_id")
            if try results.string("proposal_id") != proposalID { throw ResultsProblem("results") }
            var choices = Set<String>()
            for c in try proposal.array("choices") {
                let id = try c.asObject().string("id")
                if !validChoice(id) || !choices.insert(id).inserted { throw ResultsProblem("results") }
            }
            var tally: [String: UInt64] = [:]
            for (name, value) in try results.obj("tally").members {
                tally[name] = try value.asUint(min: 0, max: eligible)
            }
            // Names are unique (a strict parse), so equal sets are the same choices, each once.
            if Set(tally.keys) != choices { throw ResultsProblem("tally") }
            return Observed(
                ballots: ballots, tally: tally, proposalHash: Bytes.sha256(proposalBytes),
                recordRoot: try proposal.base64("record_root", VoteMerkle.hashSize), choices: choices, proposalID: proposalID
            )
        } catch let p as ResultsProblem {
            throw p
        } catch {
            throw ResultsProblem("results")
        }
    }

    /// The rows of `rows.json`: as many as [eligible] (the tree's size is `counts.eligible`), each with its tag and a
    /// leaf. Rows out of order or repeated (§8.2: another order is not the tree the roots were made over), or with members
    /// other than §8.5's, still make their leaves (the proof is checked against the signed root all the same) and are
    /// the problem returned, and so is a document that is not exactly `v` 1, `proposal_id` and `rows` (§8.5); a row
    /// whose leaf can't be made at all, or a document nested deeper than a ballot, is thrown.
    private static func readRows(_ bytes: [UInt8], eligible: UInt64) throws -> ReadRows {
        do {
            // No deeper than a ballot: a deeper document makes no tree, and stops the submit (chosen; not in the spec).
            let top = try StrictJson.parseObject(bytes, maxDepth: 4)
            let items = try top.array("rows")
            if UInt64(items.count) != eligible { throw ResultsProblem("rows_count") }
            var out: [Row] = []
            out.reserveCapacity(items.count)
            var problem: ResultsProblem?
            if !only(top, ["v", "proposal_id", "rows"]) || (try? top.uint("v", min: 1, max: 1)) != 1 {
                problem = ResultsProblem("rows")
            }
            for e in items {
                let (row, rowProblem) = try readRow(e)
                if let previous = out.last?.tag, !previous.lexicographicallyPrecedes(row.tag) {
                    problem = problem ?? ResultsProblem("rows_order")
                }
                problem = problem ?? rowProblem
                out.append(row)
            }
            return ReadRows(rows: out, problem: problem, proposalID: try? top.string("proposal_id"))
        } catch let p as ResultsProblem {
            throw p
        } catch {
            throw ResultsProblem("rows")
        }
    }

    /// One row with its leaf, and its problem when it is not exactly `record_tag` and `ballot`, a ballot exactly `vk`,
    /// `choice_id` and `ballot_sig` (§8.5: a verifier refuses unknown or missing fields), or a ballot the vault would not
    /// read. Throws when no leaf can be made of it: no tag of 32 bytes, or a ballot that is neither null nor an object
    /// (chosen; not in the spec: without a leaf there is no tree, and nothing to submit).
    private static func readRow(_ e: JsonValue) throws -> (Row, ResultsProblem?) {
        let row = try e.asObject()
        let tag = try row.base64("record_tag", VoteMerkle.hashSize)
        var problem = only(row, ["record_tag", "ballot"]) ? nil : ResultsProblem("rows")
        switch row["ballot"] {
        case .null?, nil: return (Row(tag: tag, ballot: nil, leaf: tag), problem)
        case let v?:
            let ballot = try v.asObject()
            let strict = try? leaf(tag: tag, ballot: ballot)
            if !only(ballot, ["vk", "choice_id", "ballot_sig"]) || strict == nil { problem = problem ?? ResultsProblem("rows") }
            return (Row(tag: tag, ballot: ballot, leaf: try strict ?? looseLeaf(tag: tag, ballot: ballot)), problem)
        }
    }

    /// `ballot_leaf` (§5): `record_tag || lp(vk) || lp(choice_id) || lp(ballot_sig)`, `lp(x) = u16(len x) || x`.
    static func leaf(tag: [UInt8], ballot b: JsonObject) throws -> [UInt8] {
        let vk: [UInt8]
        let sig: [UInt8]
        let id: String
        do {
            vk = try b.base64("vk", keySize)
            sig = try b.base64("ballot_sig", sigSize)
            id = try b.string("choice_id")
        } catch {
            throw ResultsProblem("rows")
        }
        // [a-z0-9-]{1,32}, as vettid-vault's ValidChoiceID: a row with another id is not one the vault would accept.
        if !validChoice(id) { throw ResultsProblem("rows") }
        return Bytes.concat(tag, lp(vk), lp(Array(id.utf8)), lp(sig))
    }

    /// The same leaf for a ballot of other rows than the vault reads (a key or signature of another length, a choice id
    /// outside `[a-z0-9-]{1,32}`): still a leaf of the published tree. Throws when its members are no base64 or string
    /// (chosen; not in the spec: such a ballot has no bytes to make a leaf of, so there is no tree and nothing to submit).
    static func looseLeaf(tag: [UInt8], ballot b: JsonObject) throws -> [UInt8] {
        let vk: [UInt8]
        let sig: [UInt8]
        let id: [UInt8]
        do {
            vk = try b.base64("vk")
            sig = try b.base64("ballot_sig")
            id = Array(try b.string("choice_id").utf8)
        } catch {
            throw ResultsProblem("rows")
        }
        guard [vk, sig, id].allSatisfy({ $0.count <= 0xFFFF }) else { throw ResultsProblem("rows") }
        return Bytes.concat(tag, lp(vk), lp(id), lp(sig))
    }

    /// Whether [o] has exactly the members [names] (names are unique: a strict parse).
    private static func only(_ o: JsonObject, _ names: Set<String>) -> Bool {
        o.members.count == names.count && o.members.allSatisfy { names.contains($0.name) }
    }

    /// `[a-z0-9-]{1,32}`.
    private static func validChoice(_ id: String) -> Bool {
        let c = Array(id.utf8)
        return !c.isEmpty && c.count <= maxId && c.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }

    private static func lp(_ x: [UInt8]) -> [UInt8] { Bytes.concat(Bytes.uintBE(UInt64(x.count), 2), x) }
}
