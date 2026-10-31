import Foundation
import Testing
@testable import VettIDCrypto
@testable import VettIDData

/// The member's own row of the results is submitted only if the vault takes it: a `choice_id` of 1 to 32 bytes of
/// `[a-z0-9-]` (VAULT-MESSAGING 0.81.6 §10.19.8 "Choice ids in results"; the vault's `ValidChoiceID`). Otherwise
/// ``VoteSiteRunner/submitBody(_:doc:sig:bundle:own:)`` has no body and the attempt is the problem hint.
@MainActor
struct VoteResultsChoiceTests {
    func body(choice: String) throws -> [UInt8]? {
        let vk = Base64s.encodeStd([UInt8](repeating: 3, count: 32))
        let sig = Base64s.encodeStd([UInt8](repeating: 4, count: 64))
        let ballot = try StrictJson.parseObject(#"{"vk":"\#(vk)","choice_id":"\#(choice)","ballot_sig":"\#(sig)"}"#)
        let row = OwnRow(ballot: ballot, index: 0, treeSize: 1, path: [])
        return VoteSiteRunner.submitBody(VoteFixture.key, doc: [1], sig: [UInt8](repeating: 5, count: 64), bundle: "{}", own: row)
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
        let row = OwnRow(ballot: nil, index: 0, treeSize: 1, path: [])
        let b = VoteSiteRunner.submitBody(VoteFixture.key, doc: [1], sig: [UInt8](repeating: 5, count: 64), bundle: "{}", own: row)
        #expect(b != nil)
    }
}
