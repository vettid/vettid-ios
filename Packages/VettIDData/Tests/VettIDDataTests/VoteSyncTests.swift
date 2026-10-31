import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData

/// The plan of the work with the public votes site (VAULT-MESSAGING 0.81.6 §10.19.8 `vote.site.sync`; ANDROID-PLAN
/// 0.1.107): which lists go and how they are split, how entries are batched, and what an entry says. Mirrors the
/// planning part of vettid-android `VoteSyncTest`.
struct VoteSyncTests {
    static func list(_ v: Int64, size: Int = 64) -> VoteSync.ServedList {
        let head = Array(#"{"version":\#(v),"pad":""#.utf8)
        let pad = [UInt8](repeating: UInt8(ascii: "x"), count: max(0, size - head.count - 2))
        return VoteSync.ServedList(doc: head + pad + Array(#""}"#.utf8), sig: [UInt8](repeating: 7, count: 64), version: v)
    }

    static func sha(_ l: VoteSync.ServedList) -> String { Base64s.encodeStd(Bytes.sha256(l.doc)) }

    static func services(_ body: [UInt8]) throws -> [Int64] {
        try StrictJson.parseObject(body).array("services").map { v in
            let doc = try Base64s.decodeStd(try v.asObject().string("doc"))
            return try #require(VoteSync.versionOf(doc))
        }
    }

    @Test func aListIsSentOnlyWhenItDiffersFromTheHeldOne() throws {
        let v3 = Self.list(3)
        #expect(VoteSync.planLists(v3, heldVersion: nil, heldSha256: nil, between: []) == .send([v3]))
        #expect(VoteSync.planLists(v3, heldVersion: 3, heldSha256: Self.sha(v3), between: []) == .confirm(version: 3, sha256: Self.sha(v3)))
        // Same version, other bytes: sent, the vault judges. An older one is not sent.
        #expect(VoteSync.planLists(v3, heldVersion: 3, heldSha256: "other", between: []) == .send([v3]))
        #expect(VoteSync.planLists(v3, heldVersion: 4, heldSha256: "other", between: []) == .nothing)
        let body = VoteSync.confirmCall(version: 3, sha256: Self.sha(v3))
        let c = try StrictJson.parseObject(body).obj("services_confirm")
        #expect(try c.uint("version", min: 0, max: 10) == 3 && c.string("sha256") == Self.sha(v3))
    }

    @Test func aCatchUpGoesInVersionOrderAndStopsAtAMissingCopy() {
        let v1 = Self.list(1), v2 = Self.list(2), v3 = Self.list(3), v4 = Self.list(4)
        #expect(VoteSync.planLists(v4, heldVersion: 1, heldSha256: "x", between: [v2, v3]) == .send([v2, v3, v4]))
        // v3 not served yet: v2 goes now, the rest at the next run.
        #expect(VoteSync.planLists(v4, heldVersion: 1, heldSha256: "x", between: [v2]) == .send([v2]))
        #expect(VoteSync.planLists(v4, heldVersion: 1, heldSha256: "x", between: []) == .nothing)
        #expect(VoteSync.planLists(v2, heldVersion: 1, heldSha256: Self.sha(v1), between: []) == .send([v2]))
    }

    @Test func listsAreSplitEightAtMostAndABigOneAlone() throws {
        let small = (1...9).map { Self.list(Int64($0)) }
        let calls = VoteSync.listCalls(small)
        #expect(try calls.map(Self.services) == [Array(1...8), [9]])
        // A list over 1,048,576 bytes goes in a call of its own; the small ones around it in theirs.
        let big = Self.list(2, size: VoteSync.bigList + 1)
        let mixed = VoteSync.listCalls([Self.list(1), big, Self.list(3)])
        #expect(try mixed.map(Self.services) == [[1], [2], [3]])
        // A list that alone would pass the body limit is never sent, nor any after it (they cannot chain without it).
        let huge = Self.list(2, size: VoteSync.bodyMax + 1)
        #expect(try VoteSync.listCalls([Self.list(1), huge, Self.list(3)]).map(Self.services) == [[1]])
        #expect(calls.allSatisfy { $0.count <= VoteSync.bodyMax })
    }

    @Test func aCallOfListsIsNeverOverTheBodyLimitOnceEncoded() throws {
        // Seven lists of 1,000,000 bytes are about 1.33 MB each as base64: six fit in one call, the seventh goes in the next.
        let lists = (1...7).map { Self.list(Int64($0), size: 1_000_000) }
        let calls = VoteSync.listCalls(lists)
        #expect(try calls.map(Self.services) == [Array(1...6), [7]])
        #expect(calls.allSatisfy { $0.count <= VoteSync.bodyMax })
    }

    @Test func entriesAreBatchedEightAtMostAndAnOversizedOneIsLeftOut() throws {
        let entries = (1...9).map { VoteSync.entryJson("p\($0)", index: nil, .absent) }
        let calls = VoteSync.entryCalls(entries)
        #expect(try calls.map { try StrictJson.parseObject($0).array("entries").count } == [8, 1])
        let huge = VoteSync.entryJson("big", index: nil, .found(
            proposal: [UInt8](repeating: 1, count: VoteSync.bodyMax), proposalSig: nil, bundle: nil, extensions: []
        ))
        let kept = VoteSync.entryCalls([entries[0], huge, entries[1]])
        #expect(try kept.map { try StrictJson.parseObject($0).array("entries").count } == [2])
    }

    @Test func anEntryCarriesNoTimeAndTheDocumentsAsServed() throws {
        let absent = try StrictJson.parseObject(VoteSync.entryJson("p1", index: nil, .absent))
        #expect(try absent.string("proposal_id") == "p1" && absent.obj("document").string("status") == "absent")
        #expect(absent.members.map(\.name) == ["proposal_id", "document"])
        #expect(try absent.obj("document").members.map(\.name) == ["status"])
        let unreachable = try StrictJson.parseObject(VoteSync.entryJson("p1", index: #"{"proposal_id":"p1"}"#, .unreachable))
        #expect(try unreachable.obj("document").string("status") == "unreachable")
        #expect(try unreachable.obj("index").string("proposal_id") == "p1")
        let found = try StrictJson.parseObject(VoteSync.entryJson("p1", index: nil, .found(
            proposal: Array("odd".utf8), proposalSig: [9, 9], bundle: #"{"b":1}"#,
            extensions: [VoteSync.Extension(Array("x1".utf8), sig: nil, bundle: nil)]
        )))
        let d = try found.obj("document")
        #expect(try d.string("status") == "found" && d.base64("proposal") == Array("odd".utf8))
        #expect(try d.base64("proposal_sig") == [9, 9] && d.obj("bundle").uint("b", min: 0, max: 9) == 1)
        let x = try d.array("extensions").map { try $0.asObject() }
        #expect(try x.count == 1 && x[0].base64("extension") == Array("x1".utf8) && !x[0].has("extension_sig"))
    }

    @Test func anExtensionIsSentWithExactlyTheMembersTheVaultReads() throws {
        let sig = [UInt8](repeating: 7, count: 64)
        let e = try StrictJson.parseObject(VoteSync.entryJson("p1", index: nil, .found(
            proposal: Array("p".utf8), proposalSig: sig, bundle: nil,
            extensions: [VoteSync.Extension(Array("x1".utf8), sig: sig, bundle: #"{"b":2}"#)]
        )))
        let x = try e.obj("document").array("extensions").map { try $0.asObject() }
        #expect(x.count == 1)
        #expect(x[0].has("bundle") && x[0].has("extension") && x[0].has("extension_sig") && !x[0].has("docsig") && !x[0].has("sig"))
        #expect(try x[0].base64("extension_sig", 64) == sig && x[0].base64("extension") == Array("x1".utf8))
        #expect(try x[0].obj("bundle").uint("b", min: 0, max: 9) == 2)
    }

    @Test func aBodyGoesInlineOnlyWhenItsPaddedEnvelopeFits() {
        #expect(VoteSync.fitsInline(Array(#"{"entries":[]}"#.utf8)))
        func body(_ n: Int) -> [UInt8] { Array(#"{"pad":""#.utf8) + [UInt8](repeating: 0x61, count: n) + Array(#""}"#.utf8) }
        #expect(VoteSync.fitsInline(body(200_000)))
        // At the cap the envelope's own members (v, id, type, ts, seq) push it over.
        #expect(!VoteSync.fitsInline(body(VoteSync.inlineMax - 10)))
        #expect(!VoteSync.fitsInline(body(4_194_304)))
    }

    @Test func theIndexIsReadAsServedAndAnOddOneYieldsNothing() {
        let a = "01JBQZ0000000000000000000A"
        let b = "01JBQZ0000000000000000000B"
        let index = Array(#"[{"proposal_id":"\#(a)","extended":2, "opens_at":0},{"x":1},7,{"proposal_id":"\#(b)"}]"#.utf8)
        let read = VoteSync.indexOf(index)
        #expect(read.map(\.proposalID) == [a, b])
        #expect(read[0].json == #"{"proposal_id":"\#(a)","extended":2,"opens_at":0}"#)
        #expect(VoteSync.extendedOf(read[0].json) == 2 && VoteSync.extendedOf(read[1].json) == nil)
        #expect(VoteSync.indexOf(Array("not json".utf8)).isEmpty)
        #expect(VoteSync.indexOf(Array(#"{"proposal_id":"\#(a)"}"#.utf8)).isEmpty)
    }

    @Test func theIndexIsSplitByAScanThatKnowsStringsAndNesting() {
        let a = "01JBQZ0000000000000000000A"
        let b = "01JBQZ0000000000000000000B"
        let text = #" [ {"proposal_id":"\#(a)","t":"x],{[,\"}"} , {"proposal_id":"\#(b)","n":[1,[2,{"k":"]"}]]} ] "#
        let read = VoteSync.indexOf(Array(text.utf8))
        #expect(read.map(\.proposalID) == [a, b] && read.allSatisfy { $0.json != nil })
        // Not one array, unbalanced, or with something after it.
        for bad in ["{}", "[", "[{]", "[{}] x", "[}]", ""] { #expect(VoteSync.indexOf(Array(bad.utf8)).isEmpty, Comment(rawValue: bad)) }
    }

    @Test func anIndexElementOverTheCapIsLeftOutBeforeAnyParse() {
        let a = "01JBQZ0000000000000000000A"
        let b = "01JBQZ0000000000000000000B"
        func element(_ id: String, size: Int) -> String {
            let head = #"{"proposal_id":"\#(id)","p":""#
            return head + String(repeating: "x", count: size - head.utf8.count - 2) + #""}"#
        }
        let cap = VoteSiteLimits.indexElementMax
        let index = "[" + element(a, size: cap) + "," + element(b, size: cap + 1) + "]"
        #expect(VoteSync.indexOf(Array(index.utf8)).map(\.proposalID) == [a])
    }

    /// A lone surrogate escape is read as U+FFFD, as the vault reads it: two names that differ only in it are one name.
    @Test func aLoneSurrogateCollidingNamesLeaveOutTheValueAndWhatIsSentIsCheckedAgain() {
        for doc in [#"{"\ud800":1,"\ud801":2}"#, #"{"a\ud800":1,"a\udfff":2}"#, #"{"x":{"\ud800":1,"\ud83d":2}}"#] {
            #expect(VoteSync.compactObject(Array(doc.utf8), level: VoteSync.Level.proposalBundle) == nil, Comment(rawValue: doc))
        }
        // Distinct names, a pair read as one scalar, and white space only outside strings: sent as the compact original.
        let ok = #"{ "\ud800\udc00" : 1 , "\ud800" : [ 2 ] }"#
        #expect(VoteSync.compactObject(Array(ok.utf8), level: VoteSync.Level.proposalBundle) == #"{"\ud800\udc00":1,"\ud800":[2]}"#)
        let index = Array(#"[{"proposal_id":"01JBQZ0000000000000000000A","\ud800":1,"\ud801":2}]"#.utf8)
        #expect(VoteSync.indexOf(index).isEmpty)
    }

    @Test func theLevelsCountTheInnerMessageAsOneAndTheBodyAsTwo() {
        #expect(VoteSync.Level.index == 5 && VoteSync.Level.proposalBundle == 6)
        #expect(VoteSync.Level.extensionBundle == 8 && VoteSync.Level.resultsBundle == 3)
        func nested(_ d: Int) -> [UInt8] {
            Array((String(repeating: #"{"a":"#, count: d - 1) + "{}" + String(repeating: "}", count: d - 1)).utf8)
        }
        for (level, own) in [(5, 28), (6, 27), (8, 25), (3, 30)] {
            #expect(VoteSync.compactObject(nested(own), level: level) != nil)
            #expect(VoteSync.compactObject(nested(own + 1), level: level) == nil)
        }
    }

    @Test(arguments: ["[}]", "[1}", "[{]}", "[,]", "[{", "[]", "[", "]", "[[[[[[", "[\"", "[\"\\", "[{\"a\":[}", ""])
    func theIndexSplitterEndsQuicklyOnBrokenInput(_ text: String) {
        let clock = ContinuousClock()
        let took = clock.measure { #expect(VoteSync.indexOf(Array(text.utf8)).isEmpty) }
        #expect(took < .seconds(1))
    }

    @Test func aHugeBrokenIndexIsScannedOnceAndQuickly() {
        let clock = ContinuousClock()
        let big = [UInt8](repeating: UInt8(ascii: "["), count: VoteSiteLimits.indexMax)
        let took = clock.measure {
            #expect(VoteSync.indexOf(big).isEmpty)
            #expect(VoteSync.indexOf([UInt8(ascii: "[")] + [UInt8](repeating: UInt8(ascii: "}"), count: VoteSiteLimits.indexMax)).isEmpty)
        }
        #expect(took < .seconds(5))
    }

    @Test func anIndexIdThatIsNoUlidIsNotUsedInAPath() {
        let bad = ["p1", "../x", "01JBQZ0000000000000000000A/../..", "01JBQZ000000000000000000?", "01jbqz0000000000000000000a", ""]
        let index = "[" + bad.map { #"{"proposal_id":"\#($0)"}"# }.joined(separator: ",") + "]"
        #expect(VoteSync.indexOf(Array(index.utf8)).isEmpty)
    }
}
