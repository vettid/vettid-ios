import Foundation
import Testing
@testable import VettIDCrypto
@testable import VettIDData

/// The member's own row of the results is submitted only if the vault takes it: a `choice_id` of 1 to 32 bytes of
/// `[a-z0-9-]` (VAULT-MESSAGING 0.81.6 §10.19.8 "Choice ids in results"; the vault's `ValidChoiceID`). Otherwise
/// ``ResultsBody/build(_:doc:sig:bundle:rows:)`` has no body and the attempt is the problem hint (or `rows_unavailable` for
/// a vault with `vote_rows`).
@MainActor
struct VoteResultsChoiceTests {
    static let vk = Base64s.encodeStd([UInt8](repeating: 3, count: 32))
    static let sig = Base64s.encodeStd([UInt8](repeating: 4, count: 64))

    func row(choice: String, index: UInt64 = 0, vk: String = Self.vk, sig: String = Self.sig) throws -> OwnRow {
        let ballot = try StrictJson.parseObject(#"{"vk":"\#(vk)","choice_id":"\#(choice)","ballot_sig":"\#(sig)"}"#)
        return OwnRow(ballot: ballot, index: index, treeSize: 8, path: [[UInt8](repeating: 9, count: 32)])
    }

    func build(_ rows: SubmittedRows) -> [UInt8]? {
        ResultsBody.build(VoteFixture.key, doc: [1], sig: [UInt8](repeating: 5, count: 64), bundle: "{}", rows: rows)
    }

    func body(choice: String) throws -> [UInt8]? {
        build(SubmittedRows(own: try row(choice: choice), others: []))
    }

    @Test(arguments: ["a", "yes", "a-b-0", String(repeating: "a", count: 32), "-", "0"])
    func aValidChoiceIDIsSubmitted(_ choice: String) throws {
        #expect(try body(choice: choice) != nil)
    }

    @Test(arguments: ["", String(repeating: "a", count: 33), "Yes", "yeS", "a_b", "a b", "é", "ja\u{e4}", "a/b", "日本"])
    func anInvalidChoiceIDIsNotSubmitted(_ choice: String) throws {
        #expect(try body(choice: choice) == nil)
    }

    @Test func aRowWithoutABallotIsSubmittedAsNull() throws {
        let b = build(SubmittedRows(own: OwnRow(ballot: nil, index: 0, treeSize: 1, path: []), others: []))
        #expect(b != nil)
    }

    private func object(_ bytes: [UInt8]?) throws -> JsonObject { try StrictJson.parseObject(try #require(bytes)) }

    /// `pad` (VAULT-MESSAGING 0.83.6 §10.19.5) on the row's ballot, so that the request has one size for every choice id.
    @Test func theRowsBallotCarriesItsPadAndTheBodyHasOneSizeForEveryChoiceId() throws {
        let ballot = try object(try body(choice: "yes")).obj("row").obj("ballot")
        #expect(try ballot.string("pad") == String(repeating: "0", count: 29) && ballot.string("choice_id") == "yes")
        let sizes = try ["a", "yes", "abstain", String(repeating: "x", count: 32)].map { try #require(try body(choice: $0)).count }
        #expect(Set(sizes).count == 1)
        // The members of an empty row are as before.
        let none = SubmittedRows(own: OwnRow(ballot: nil, index: 0, treeSize: 1, path: []), others: [])
        let empty = try object(build(none)).obj("row")
        if case .null? = empty["ballot"] {} else { Issue.record("an empty row's ballot is null") }
    }

    /// The other rows under the member's tag go as `other_rows` (at most 4, §10.19.8), each with `row` (its ballot with `pad`)
    /// and `proof`; the vault judges a second row whatever its choice id, so an odd one is sent as published.
    @Test func otherRowsGoWithTheirProofsAndPad() throws {
        let odd = try row(choice: "Yes", index: 5, vk: Base64s.encodeStd([UInt8](repeating: 3, count: 33)))
        let sent = try object(build(SubmittedRows(own: try row(choice: "yes"), others: [try row(choice: "no", index: 3), odd])))
        let others = try sent.array("other_rows").map { try $0.asObject() }
        #expect(others.count == 2)
        let indexes = try others.map { try $0.obj("proof").uint("index", min: 0, max: 10) }
        #expect(indexes == [3, 5])
        #expect(try others[0].obj("row").obj("ballot").string("pad") == String(repeating: "0", count: 30))
        #expect(try others[1].obj("row").obj("ballot").string("choice_id") == "Yes")
        #expect(!sent.has("rows_unavailable"))
        // No extra rows: no `other_rows` at all.
        #expect(try !object(body(choice: "yes")).has("other_rows"))
    }

    /// `rows_unavailable: true` instead of any row (§10.19.8): no `row`, `row_proof` or `other_rows`.
    @Test func aRowThatCannotBeHadIsRowsUnavailable() throws {
        let sent = try object(build(.unavailable))
        #expect(try sent.bool("rows_unavailable") == true)
        #expect(!sent.has("row") && !sent.has("row_proof") && !sent.has("other_rows"))
        #expect(try sent.string("connection_id") == VoteFixture.key.connectionID && sent.has("results") && sent.has("bundle"))
    }

    /// Too large for the request: the largest extra rows are dropped first, down to one.
    @Test func tooManyOtherRowsAreDroppedLargestFirstDownToOne() throws {
        let rows = SubmittedRows(
            own: try row(choice: "yes"),
            others: [
                try row(choice: "a", index: 1), try row(choice: "ab", index: 2, vk: Base64s.encodeStd([UInt8](repeating: 3, count: 300))),
                try row(choice: "ab", index: 3),
            ]
        )
        var limit = 0
        let fits: ([UInt8]) -> Bool = { $0.count <= limit }
        let full = try #require(build(rows)).count
        // Room for two extra rows: the largest (index 2, with a long key) is dropped first.
        limit = full - 1
        let two = try #require(ResultsBody.fewer(rows, fits: fits, body: build))
        #expect(two.others.map(\.index) == [1, 3])
        // Room for none beyond one: the smallest is kept.
        limit = 0
        #expect(ResultsBody.fewer(rows, fits: fits, body: build) == nil)
    }
}
