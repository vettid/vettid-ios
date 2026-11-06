import Foundation
import Testing
@testable import VettIDCrypto

/// `pad` (VAULT-MESSAGING 0.83.6 §10.19.5): 32 minus the UTF-8 bytes of the `choice_id` ASCII `0`s, empty from 32 bytes up.
/// Mirrors vettid-android `VotePadTest`.
struct VotePadTests {
    @Test func padIsThirtyTwoMinusTheBytesOfTheChoiceId() {
        #expect(VotePad.of("yes") == String(repeating: "0", count: 29))
        #expect(VotePad.of("a") == String(repeating: "0", count: 31))
        #expect(VotePad.of(String(repeating: "a", count: 32)).isEmpty)
        // A foreign choice id over 32 bytes gets an empty pad, never a negative count.
        #expect(VotePad.of(String(repeating: "a", count: 33)).isEmpty && VotePad.of("").count == 32)
    }

    /// Bytes, not characters or the escaped JSON form.
    @Test func padCountsUtf8BytesNotCharacters() {
        #expect(VotePad.of("é") == String(repeating: "0", count: 30))
        #expect(VotePad.of("\u{1F5F3}") == String(repeating: "0", count: 28))
        #expect(VotePad.of("a\"b\\c") == String(repeating: "0", count: 27))
    }

    /// The body of `vote.cast` to the service in VAULT-MESSAGING §16 (0.83.6) is 418 bytes with a `pad` of 29 zeros.
    @Test func theSectionSixteenCastBodyHasThePadOfYes() throws {
        // swiftlint:disable:next line_length
        let body = #"{"proposal_id":"01JBQZ0000000000000000000A","record_tag":"3KV3h0iqHvnQqpyH2T5Oak5DkcYgE22/4iSFqlXrDBg=","vk":"BbzEtm+tOm+3zVs+ZWelbUli12gOHLqHvuDcOqL4VGI=","choice_id":"yes","ballot_sig":"BQIxgkceO2GLwUXr7hamrDat6axY1dx/74YewFtWHRcELjk58p8JkyajaJjERi430K9/nAvpCEeKJAA9tJ6iCQ==","cast_sig":"CQ5uDHvP4cFInSM0itpblrzuMjoT5dsP5wIYvAHhH/uAlP7JSrota0K8FhIVJ50mP1nbO7li32ZZscZe/kqPBw==","pad":"00000000000000000000000000000"}"#
        #expect(body.utf8.count == 418)
        let o = try StrictJson.parseObject(Array(body.utf8))
        #expect(try o.string("pad") == VotePad.of(o.string("choice_id")))
    }
}
