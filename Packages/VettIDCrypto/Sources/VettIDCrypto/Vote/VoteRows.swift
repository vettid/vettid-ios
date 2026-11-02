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
/// `vote.results.submit` (VAULT-MESSAGING §10.19.6 step 1): the hash of `rows.json`; the tags in order, unique, as many as
/// `eligible`, and their tree against the proposal's `record_root`; the rows' tree against `rows_root`; every ballot's
/// `ballot_sig` under its `vk` and its choice one of the proposal's; the tally and `ballots` recomputed; and the member's
/// row. Results that fail any of these are not submitted, and the member is told of a problem with the published results.
/// The signatures of the documents, the anchor and the verdict are the vault's; it never relies on this. Builds on
/// vettid-android `VoteRows` (the hash, order and tree), with the signatures, the tally and `record_root` added.
public enum VoteRows {
    /// The most rows read: far above any electorate a vote is held for, and small enough to bound the work on a hostile
    /// `rows.json` (the app fetches at most about 256 bytes a row of it).
    public static let maxRows = 100_000

    /// The label of `ballot_sig` (BALLOT-PROTOCOL §5), its `0x00` included (§2).
    public static let ballotLabel = "vettid/vote/1/ballot\u{0}"

    private static let keySize = 32
    private static let sigSize = 64
    private static let maxId = 32

    /// What the app reads of `results.json` and the proposal it carries.
    private struct Published {
        let rowsHash: [UInt8]
        let rowsRoot: [UInt8]
        let eligible: UInt64
        let ballots: UInt64
        let tally: [String: UInt64]
        let proposalHash: [UInt8]
        let recordRoot: [UInt8]
        let choices: Set<String>
    }

    /// One row of `rows.json`: its tag, and its ballot (`vk`, `choice_id`, `ballot_sig`) as the site has it, or nil.
    private struct Row {
        let tag: [UInt8]
        let ballot: JsonObject?
    }

    /// Checks [rowsBytes] against [resultsBytes] and returns the row of [recordTag] with its proof. Throws
    /// ``ResultsProblem`` for anything that does not hold, including a tag that has no row.
    public static func ownRow(results resultsBytes: [UInt8], rows rowsBytes: [UInt8], recordTag: [UInt8]) throws -> OwnRow {
        let published = try read(resultsBytes)
        if !Bytes.constantTimeEquals(Bytes.sha256(rowsBytes), published.rowsHash) { throw ResultsProblem("rows_hash") }
        let rows = try readRows(rowsBytes, eligible: published.eligible)
        // The tags are the electorate the signed proposal fixed before anyone voted (§8.1, §8.2: record leaves in order).
        if !Bytes.constantTimeEquals(VoteMerkle.root(rows.map(\.tag)), published.recordRoot) {
            throw ResultsProblem("record_root")
        }
        // The cheap tree check first: a hostile `rows.json` costs no signature checks unless it is the published tree.
        var leaves: [[UInt8]] = []
        leaves.reserveCapacity(rows.count)
        var found: Int?
        for (i, row) in rows.enumerated() {
            leaves.append(try row.ballot.map { try leaf(tag: row.tag, ballot: $0) } ?? row.tag)
            if Bytes.constantTimeEquals(row.tag, recordTag) { found = i }
        }
        if !Bytes.constantTimeEquals(VoteMerkle.root(leaves), published.rowsRoot) { throw ResultsProblem("rows_root") }
        try checkTally(rows, published)
        guard let found else { throw ResultsProblem("no_row") }
        guard let path = VoteMerkle.proof(leaves, found) else { throw ResultsProblem("rows") }
        return OwnRow(ballot: rows[found].ballot, index: UInt64(found), treeSize: UInt64(leaves.count), path: path)
    }

    /// §8.4 items 3 and 4: every ballot verifies and names one of the proposal's choices, and every choice's count and
    /// the number of ballots are the rows', exactly.
    private static func checkTally(_ rows: [Row], _ published: Published) throws {
        var counted: [String: UInt64] = [:]
        for row in rows {
            guard let b = row.ballot else { continue }
            counted[try ballotChoice(row.tag, b, published), default: 0] += 1
        }
        if counted.values.reduce(0, +) != published.ballots { throw ResultsProblem("ballots") }
        for choice in published.choices where counted[choice, default: 0] != published.tally[choice] {
            throw ResultsProblem("tally")
        }
    }

    /// A ballot's choice, once its choice is one of the proposal's and its `ballot_sig` verifies under its `vk` for
    /// `ballot_msg = proposal_hash || record_tag || lp(choice_id)` (§5, §8.4 item 3), by the strict rules of §2.
    private static func ballotChoice(_ tag: [UInt8], _ b: JsonObject, _ p: Published) throws -> String {
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

    /// `results.json` (§8.5) and its proposal: the hash, the roots, the counts and the tally, the proposal's hash, its
    /// `record_root` and its choice ids. A tally that names other choices than the proposal's, or not every one, is a
    /// problem.
    private static func read(_ bytes: [UInt8]) throws -> Published {
        do {
            let results = try StrictJson.parseObject(bytes)
            let counts = try results.obj("counts")
            let eligible = try counts.uint("eligible", min: 1, max: UInt64(maxRows))
            let ballots = try counts.uint("ballots", min: 0, max: eligible)
            let proposalBytes = try results.obj("proposal").base64("doc")
            let proposal = try StrictJson.parseObject(proposalBytes)
            if try proposal.uint("eligible", min: 1, max: UInt64(maxRows)) != eligible { throw ResultsProblem("results") }
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
            return Published(
                rowsHash: try results.base64("rows_hash", VoteMerkle.hashSize),
                rowsRoot: try results.base64("rows_root", VoteMerkle.hashSize),
                eligible: eligible, ballots: ballots, tally: tally, proposalHash: Bytes.sha256(proposalBytes),
                recordRoot: try proposal.base64("record_root", VoteMerkle.hashSize), choices: choices
            )
        } catch let p as ResultsProblem {
            throw p
        } catch {
            throw ResultsProblem("results")
        }
    }

    /// The rows of `rows.json`: as many as [eligible], sorted by tag and each tag once (§8.2: another order is not the
    /// tree the roots were made over).
    private static func readRows(_ bytes: [UInt8], eligible: UInt64) throws -> [Row] {
        do {
            let items = try StrictJson.parseObject(bytes).array("rows")
            if UInt64(items.count) != eligible { throw ResultsProblem("rows_count") }
            var out: [Row] = []
            out.reserveCapacity(items.count)
            for e in items {
                let row = try e.asObject()
                // §8.5: exactly these members (a verifier refuses unknown or missing fields).
                if !only(row, ["record_tag", "ballot"]) { throw ResultsProblem("rows") }
                let tag = try row.base64("record_tag", VoteMerkle.hashSize)
                if let previous = out.last?.tag, !previous.lexicographicallyPrecedes(tag) { throw ResultsProblem("rows_order") }
                switch row["ballot"] {
                case .null?: out.append(Row(tag: tag, ballot: nil))
                case let v?:
                    let ballot = try v.asObject()
                    if !only(ballot, ["vk", "choice_id", "ballot_sig"]) { throw ResultsProblem("rows") }
                    out.append(Row(tag: tag, ballot: ballot))
                case nil: throw ResultsProblem("rows")
                }
            }
            return out
        } catch let p as ResultsProblem {
            throw p
        } catch {
            throw ResultsProblem("rows")
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
