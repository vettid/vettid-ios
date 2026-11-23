import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDDevices

/// One save flow of the item's page against the real ``ItemWaysManager``, which judges widening, over fake vault calls: a widening
/// asks for the credential password and opens the unlock window with it; the narrowing after it asks for nothing.
@MainActor
@Suite struct ItemWaysFlowTests {
    /// The vault's calls: the list answers [current]; a set is recorded and answered with the item at the next version.
    final class Ops: ItemWaysOps, @unchecked Sendable {
        var current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use"]}"#
        var sets: [JsonObject] = []
        var answer = ""

        func list(_ agentID: String, _ itemID: String?) async throws -> [UInt8] { Array(#"{"items":[\#(current)]}"#.utf8) }

        func set(_ body: [UInt8]) async throws -> [UInt8] {
            let o = try StrictJson.parseObject(body)
            sets.append(o)
            let version = (try o.optUint("version", min: 1, max: StrictJson.maxSafeInteger) ?? 0) + 1
            let ways = try o.array("ways").map { JsonBuilder.quote(try $0.asString()) }.joined(separator: ",")
            answer = #"{"agent_id":"a1","item_id":"i1","version":\#(version),"ways":[\#(ways)]}"#
            return Array(answer.utf8)
        }
    }

    @Test func aWideningAsksForThePasswordAndTheNarrowingAfterItDoesNot() async throws {
        let ops = Ops()
        var opened: [String] = []
        let manager = ItemWaysManager(ops: { ops }, openWindow: { opened.append($0) })
        let devices = Samples.fake([DeviceInfo(id: "a1", kind: "agent", name: "Claude")])
        let items = FakeItems()
        let m = ItemWaysViewModel(agentID: "a1", itemID: "i1", repo: manager, devices: devices, items: items)
        await m.settle()
        // Widening: May be shown turned on.
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        #expect(ops.sets.isEmpty && m.state.prompt != nil, "nothing is sent before the password")
        m.setPassword("pw")
        m.submitPassword()
        await m.settle()
        #expect(opened == ["pw"] && ops.sets.count == 1 && m.state.prompt == nil && m.state.notice == .saved)
        #expect(try ops.sets[0].array("ways").map { try $0.asString() } == ["use", "reveal"])
        #expect(m.state.read?.ways?.version == 2)
        // Narrowing: turned off again, sent at once without the prompt.
        m.noticeShown()
        m.setReveal(false)
        m.save()
        await m.settle()
        #expect(ops.sets.count == 2 && m.state.prompt == nil && opened == ["pw"])
        #expect(try ops.sets[1].array("ways").map { try $0.asString() } == ["use"])
        #expect(m.state.read?.ways?.version == 3 && !m.state.dirty)
    }
}
