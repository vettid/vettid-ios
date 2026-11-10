import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

private func obj(_ s: String) throws -> JsonObject { try StrictJson.parseObject(Array(s.utf8)) }

/// TEST ONLY. The vault calls of ``DevicesManager``: what `device.list` and `leash.grant.list` answer, the calls in order, a
/// gate for the list and the failures by name.
/// Whether the fake session is open yet.
final class OpenFlag: @unchecked Sendable {
    var value = false
}

final class FakeDevicesOps: DevicesOps, @unchecked Sendable {
    var devices = (try? obj(#"{"devices":[]}"#))!
    var grantsAll = (try? obj(#"{"grants":[],"suspended":[]}"#))!
    var grantsByAgent: [String: JsonObject] = [:]
    var calls: [String] = []
    var gate: TestDeferred<Void>?
    var refuse: [String: String] = [:]
    /// Runs on the main actor once `device.unlink` has been answered (the vault locking while the request is on its way).
    var afterUnlink: (@MainActor @Sendable () -> Void)?

    func list() async throws -> JsonObject {
        calls.append("list")
        if let g = gate { try await g.value() }
        if let c = refuse["list"] { throw VaultOpError(type: "device.list", code: c, detail: "", body: nil) }
        return devices
    }

    func grants(_ agentID: String?) async throws -> JsonObject {
        calls.append("grants:\(agentID ?? "*")")
        if let c = refuse["grants"] { throw VaultOpError(type: "leash.grant.list", code: c, detail: "", body: nil) }
        if let agentID { return try grantsByAgent[agentID] ?? obj(#"{"grants":[],"suspended":[]}"#) }
        return grantsAll
    }

    func endAccess(_ deviceID: String) async throws {
        calls.append("end:\(deviceID)")
        if let c = refuse["end"] { throw VaultOpError(type: "device.session.end", code: c, detail: "", body: nil) }
    }

    func unlink(_ deviceID: String) async throws {
        calls.append("unlink:\(deviceID)")
        if let c = refuse["unlink"] { throw VaultOpError(type: "device.unlink", code: c, detail: "", body: nil) }
        if let hook = afterUnlink { await hook() }
    }
}

/// The devices list and the two actions of AA1 (ANDROID-PLAN 0.1.53 "Devices & agents"; VAULT-MESSAGING §10.3, §10.11). Mirrors
/// vettid-android `DevicesManagerTest`.
@MainActor
@Suite(.serialized) struct DevicesManagerTests {
    let now = OwnerCheckManager.instant("2026-10-21T12:00:00Z")!
    let ik = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    func dev(_ id: String, _ kind: String, _ name: String, created: String? = nil, session: String? = nil, active: String? = nil) -> String {
        var s = #"{"id":"\#(id)","kind":"\#(kind)","state":"active","name":"\#(name)","ik":"\#(ik)""#
        if let created { s += #","created_at":"\#(created)""# }
        if let active { s += #","last_active_at":"\#(active)""# }
        if let session { s += #","session_expires_at":"\#(session)""# }
        return s + "}"
    }

    func list(_ d: String...) throws -> JsonObject { try obj(#"{"devices":[\#(d.joined(separator: ","))]}"#) }

    func sync(_ kind: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: "sync.event", ts: now, body: Array(#"{"kind":"\#(kind)"}"#.utf8)))
    }

    func manager(_ ops: FakeDevicesOps, selfID: String? = "me", gone: Gone = Gone()) -> DevicesManager {
        DevicesManager(ops: { ops }, quietOps: { ops }, selfID: { selfID }, onDeviceGone: { gone.ids.append($0) })
    }

    final class Gone { var ids: [String] = [] }

    func fleet() throws -> JsonObject {
        try list(
            dev("d-old", "desktop", "Old desktop", created: "2026-09-01T10:00:00Z"),
            dev("a-new", "agent", "New agent", created: "2026-10-20T10:00:00Z", session: "2026-10-21T15:40:00Z", active: "2026-10-21T11:50:00Z"),
            dev("me", "app", "iPhone"),
            dev("d-new", "desktop", "New desktop", created: "2026-10-10T10:00:00Z"),
            dev("a-old", "agent", "Old agent", created: "2026-10-01T10:00:00Z"),
            dev("x", "toaster", "Odd", created: "2026-10-05T10:00:00Z"),
            dev("a-none", "agent", "No date")
        )
    }

    @Test func thisPhoneFirstThenAgentsThenDesktopsEachNewestFirst() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let m = manager(ops)
        try await m.refresh()
        let d = m.devices
        // The agents newest first (an entry without a date last), then desktops, an unknown kind among them.
        #expect(d.map(\.id) == ["me", "a-new", "a-old", "a-none", "d-new", "x", "d-old"])
        #expect(d[0].thisPhone && d[1].isAgent && d.last?.isDesktop == true)
        // An unknown kind keeps its own value as its role.
        #expect(d.first { $0.id == "x" }?.kind == "toaster")
        #expect(m.load == .loaded)
    }

    @Test func anEntryWithoutAnIdIsNotListedAndANameIsCleaned() throws {
        let body = try obj(#"{"devices":[{"kind":"agent","name":"No id"},{"id":"a1","kind":"agent","name":"  Re\u0000d‮   Team  "},{"id":"","kind":"agent"},"junk"]}"#)
        let d = DeviceWire.devices(body, selfID: nil)
        #expect(d.map(\.id) == ["a1"])
        // Control and format characters dropped; inner white space stays (§10.8).
        #expect(d[0].name == "Red   Team")
        // A tag character (U+E0041) is dropped whole.
        #expect(DeviceWire.cleanName("a\u{E0041}b") == "ab")
        #expect(DeviceWire.cleanName("a\u{2003}\u{00A0}b") == "a\u{2003}\u{00A0}b")
        #expect(DeviceWire.cleanName(String(repeating: "x", count: 200)).count == DeviceWire.maxName)
        // The cap and the cleaning together: no trailing space after the cut, an invisible name is empty.
        #expect(DeviceWire.cleanName("\u{202E}" + String(repeating: "x", count: DeviceWire.maxName - 1) + " yy").count == DeviceWire.maxName - 1)
        #expect(DeviceWire.cleanName("\u{3164}\u{200D}").isEmpty)
        // A cut never splits a grapheme cluster: a family emoji of 7 code points at the end of 62 letters stays or goes whole.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        #expect(DeviceWire.cleanName(String(repeating: "x", count: 62) + family) == String(repeating: "x", count: 62))
    }

    @Test func aNameThatShowsNothingFallsBackToTheProfileName() throws {
        // U+2800 and U+3164 are not White_Space: the raw text is not blank, but it shows nothing (§10.8 step 4).
        for blank in ["\u{2800}", "\u{3164}", "\u{2800} \u{3164}"] {
            let body = try obj(#"{"devices":[{"id":"a1","kind":"agent","name":"\#(blank)","profile":{"name":"Riley"}}]}"#)
            #expect(DeviceWire.devices(body, selfID: nil).single?.name == "Riley", "\(blank.unicodeScalars.map(\.value))")
        }
        // The profile's name when there is no `name`, and none at all.
        #expect(DeviceWire.devices(try obj(#"{"devices":[{"id":"a1","kind":"agent","profile":{"name":"Riley"}}]}"#), selfID: nil).single?.name == "Riley")
        #expect(DeviceWire.devices(try obj(#"{"devices":[{"id":"a1","kind":"agent"}]}"#), selfID: nil).single?.name == "")
    }

    @Test func theSessionShownIsDroppedOncePast() throws {
        let d = try #require(DeviceWire.devices(try list(dev("a", "agent", "A", session: "2026-10-21T15:40:00Z")), selfID: nil).single)
        #expect(d.hasAccess(now))
        #expect(!d.hasAccess(OwnerCheckManager.instant("2026-10-21T15:40:00Z")!))
        #expect(!d.hasAccess(OwnerCheckManager.instant("2026-10-22T00:00:00Z")!))
        let none = try #require(DeviceWire.devices(try list(dev("b", "agent", "B")), selfID: nil).single)
        #expect(!none.hasAccess(now))
    }

    @Test func theFingerprintIsEightGroupsOfFourHexDigits() throws {
        let d = try #require(DeviceWire.devices(try list(dev("a", "agent", "A")), selfID: nil).single)
        let fp = try #require(d.fingerprint)
        #expect(fp.wholeMatch(of: /([0-9a-f]{4} ){7}[0-9a-f]{4}/) != nil)
        let bad = DeviceWire.devices(try obj(#"{"devices":[{"id":"z","kind":"agent","ik":"not base64"}]}"#), selfID: nil).single
        #expect(bad != nil && bad?.fingerprint == nil)
    }

    @Test func aSuspendedAgentIsMarkedFromTheGrantList() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        ops.grantsAll = try obj(#"{"grants":[],"suspended":["a-old","d-new"]}"#)
        let m = manager(ops)
        try await m.refresh()
        #expect(Set(m.devices.filter(\.paused).map(\.id)) == ["a-old"])
    }

    @Test func theGrantListIsNotAskedWithoutAnAgentAndItsFailureLeavesTheList() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try list(dev("d", "desktop", "D"))
        let m = manager(ops)
        try await m.refresh()
        #expect(!ops.calls.contains { $0.hasPrefix("grants") })
        ops.devices = try fleet()
        ops.refuse["grants"] = "unsupported_type"
        try await m.refresh()
        #expect(m.devices.count == 7)
        #expect(m.devices.allSatisfy { !$0.paused })
    }

    /// A failed `leash.grant.list` never clears a pause the list already knew (fail closed): the flags are kept.
    @Test func aFailedGrantListKeepsThePausedFlagsAlreadyKnown() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        ops.grantsAll = try obj(#"{"grants":[],"suspended":["a-old"]}"#)
        let m = manager(ops)
        try await m.refresh()
        #expect(Set(m.devices.filter(\.paused).map(\.id)) == ["a-old"])
        ops.refuse["grants"] = "internal"
        try await m.refresh()
        #expect(Set(m.devices.filter(\.paused).map(\.id)) == ["a-old"])
        // A read that answers replaces them.
        ops.refuse["grants"] = nil
        ops.grantsAll = try obj(#"{"grants":[],"suspended":[]}"#)
        try await m.refresh()
        #expect(m.devices.allSatisfy { !$0.paused })
    }

    @Test func aFailedReadSaysSoAndKeepsWhatWasRead() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let m = manager(ops)
        try await m.refresh()
        ops.refuse["list"] = "owner_check_required"
        do {
            try await m.refresh()
            Issue.record("expected a failure")
        } catch let e as VaultFailure {
            #expect(e.kind == .ownerCheckRequired)
        }
        #expect(m.load == .failed)
        #expect(m.devices.count == 7)
    }

    @Test func theListIsClearedAtLockAndALateReadIsNotApplied() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let gate = TestDeferred<Void>()
        ops.gate = gate
        let m = manager(ops)
        let job = Task { try await m.refresh() }
        #expect(await eventually { ops.calls.contains("list") })
        // The vault locks while the read is on its way.
        m.clear()
        gate.complete()
        try await job.value
        #expect(m.devices.isEmpty)
        #expect(m.load == .notLoaded)
        // And what was read is dropped at a clear, with the "removed" notice.
        ops.gate = nil
        try await m.refresh()
        #expect(m.devices.count == 7)
        m.clear()
        #expect(m.devices.isEmpty && m.removed == nil)
    }

    /// A read in flight across a clear (a hold) ends not loaded and empty, never LOADED with an empty list.
    @Test func aReadInFlightAcrossAClearLeavesNotLoadedAndEmpty() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let m = manager(ops)
        try await m.refresh()
        #expect(m.load == .loaded)
        let gate = TestDeferred<Void>()
        ops.gate = gate
        let job = Task { try await m.refresh() }
        #expect(await eventually { ops.calls.filter { $0 == "list" }.count == 2 })
        m.clear()
        gate.complete()
        try await job.value
        #expect(m.devices.isEmpty)
        #expect(m.load == .notLoaded)
    }

    @Test func theKindsOfSyncEventThatChangeTheListReadItOnceInAFlurry() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let gate = TestDeferred<Void>()
        ops.gate = gate
        let m = manager(ops)
        m.onEvent(sync("device.paired"))
        #expect(await eventually { ops.calls.contains("list") })
        // One in flight; the others queue behind it as one.
        m.onEvent(sync("device.unlinked"))
        m.onEvent(sync("device.session"))
        m.onEvent(sync("leash.agent.suspended"))
        m.onEvent(sync("message.read"))
        gate.complete()
        #expect(await eventually { ops.calls.filter { $0 == "list" }.count >= 2 })
        // A deterministic end: a read through the same gate runs after every queued one, and counts as the third.
        try await m.refresh()
        #expect(ops.calls.filter { $0 == "list" }.count == 3)
    }

    @Test func onlySyncEventsOfTheListKindsReadTheList() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let m = manager(ops)
        m.onEvent(sync("message.read"))
        m.onEvent(VaultMessage(inner: Inner(id: Ulid.new(), type: "feed.event", ts: now, body: Array(#"{"kind":"device.paired"}"#.utf8))))
        try await m.refresh()
        #expect(ops.calls.filter { $0 == "list" }.count == 1)
    }

    @Test func endingAccessDropsTheSessionAndTheDevicesRequestsAndReadsAgain() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let gone = Gone()
        let m = manager(ops, gone: gone)
        try await m.refresh()
        #expect(m.devices.first { $0.id == "a-new" }?.sessionExpiresAt != nil)
        try await m.endAccess("a-new")
        #expect(m.devices.first { $0.id == "a-new" }?.sessionExpiresAt == nil)
        #expect(gone.ids == ["a-new"])
        #expect(ops.calls.contains("end:a-new"))
        // The quiet read that follows.
        #expect(await eventually { ops.calls.filter { $0 == "list" }.count == 2 })
    }

    @Test func aRefusedEndOfAccessLeavesTheSessionAndTheRequests() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let gone = Gone()
        let m = manager(ops, gone: gone)
        try await m.refresh()
        ops.refuse["end"] = "not_found"
        do {
            try await m.endAccess("a-new")
            Issue.record("expected a failure")
        } catch let e as VaultFailure {
            #expect(e.kind == .notFound)
        }
        #expect(m.devices.first { $0.id == "a-new" }?.sessionExpiresAt != nil)
        #expect(gone.ids.isEmpty)
    }

    @Test func removingADeviceListsItNoMoreNamesItForTheNoticeAndDropsItsRequests() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let gone = Gone()
        let m = manager(ops, gone: gone)
        try await m.refresh()
        try await m.remove("a-old")
        #expect(m.devices.allSatisfy { $0.id != "a-old" })
        #expect(m.removed?.name == "Old agent")
        #expect(gone.ids == ["a-old"])
        m.dismissRemoved()
        #expect(m.removed == nil)
    }

    @Test func aLockDuringARemovalLeavesTheClearedListAloneButStillCleansApprovals() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let gone = Gone()
        let m = manager(ops, gone: gone)
        ops.afterUnlink = { m.clear() } // the vault locks while the request is on its way
        try await m.refresh()
        try await m.remove("a-old")
        #expect(m.devices.isEmpty)
        #expect(m.removed == nil)
        #expect(gone.ids == ["a-old"])
    }

    @Test func anotherAppEntryIsNeverEndedOrRemoved() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try list(dev("me", "app", "iPhone"), dev("app2", "app", "Old phone"))
        let m = manager(ops)
        try await m.refresh()
        await #expect(throws: VaultFailure.self) { try await m.endAccess("app2") }
        await #expect(throws: VaultFailure.self) { try await m.remove("app2") }
        #expect(!ops.calls.contains { $0.hasPrefix("end:") || $0.hasPrefix("unlink:") })
    }

    @Test func aFailedRemovalChangesNothing() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let gone = Gone()
        let m = manager(ops, gone: gone)
        try await m.refresh()
        ops.refuse["unlink"] = "forbidden"
        await #expect(throws: VaultFailure.self) { try await m.remove("a-old") }
        #expect(m.devices.contains { $0.id == "a-old" })
        #expect(m.removed == nil)
        #expect(gone.ids.isEmpty)
    }

    @Test func thisPhoneIsNeverEndedOrRemovedAndNothingIsSent() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let m = manager(ops)
        try await m.refresh()
        await #expect(throws: VaultFailure.self) { try await m.endAccess("me") }
        await #expect(throws: VaultFailure.self) { try await m.remove("me") }
        #expect(!ops.calls.contains { $0.hasPrefix("end:") || $0.hasPrefix("unlink:") })
    }

    @Test func aFailingApprovalsCleanUpDoesNotTurnADoneRemovalIntoAFailure() async throws {
        struct Store: Error {}
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let m = DevicesManager(ops: { ops }, quietOps: { ops }, selfID: { "me" }, onDeviceGone: { _ in throw Store() })
        try await m.refresh()
        try await m.remove("a-old")
        #expect(m.devices.allSatisfy { $0.id != "a-old" })
    }

    @Test func theRemovalBoundIsTheLongestStatusLifetimePlusAMinute() async throws {
        let ops = FakeDevicesOps()
        ops.grantsByAgent["a"] = try obj(#"{"grants":[{"grant_id":"g1","status_ttl":300},{"grant_id":"g2"},{"grant_id":"g3","status_ttl":3600}],"suspended":[]}"#)
        ops.grantsByAgent["b"] = try obj(#"{"grants":[{"grant_id":"g1","status_ttl":120},{"grant_id":"g2"}],"suspended":[]}"#)
        ops.grantsByAgent["none"] = try obj(#"{"grants":[],"suspended":[]}"#)
        let m = manager(ops)
        #expect(await m.removalBoundSeconds("a") == 3_660)
        // A grant without a `status_ttl` is the default 15 minutes.
        #expect(await m.removalBoundSeconds("b") == 960)
        // No permission left: nothing is said.
        #expect(await m.removalBoundSeconds("none") == 0)
        // The call named the agent.
        #expect(ops.calls == ["grants:a", "grants:b", "grants:none"])
    }

    @Test func whenTheVaultCannotBeAskedTheBoundIsTheWorstCaseNeverShorter() async throws {
        let ops = FakeDevicesOps()
        ops.refuse["grants"] = "internal"
        let m = manager(ops)
        #expect(await m.removalBoundSeconds("a") == 3_660)
    }

    @Test func aGrantThatDoesNotReadCountsAsTheLongest() throws {
        #expect(DeviceWire.statusTtls(try obj(#"{"grants":"nope"}"#)) == [3_600])
        #expect(DeviceWire.statusTtls(try obj("{}")) == [3_600])
        let ttls = DeviceWire.statusTtls(try obj(#"{"grants":[{"status_ttl":"x"},{"status_ttl":99999},"junk",{"status_ttl":10},{"status_ttl":1.5},{"status_ttl":null},{}]}"#))
        #expect(ttls == [3_600, 3_600, 3_600, 60, 3_600, 3_600, 900])
        // An object or an array does not read either: the longest, never the default.
        #expect(DeviceWire.statusTtls(try obj(#"{"grants":[{"status_ttl":{"s":5}},{"status_ttl":[5]}]}"#)) == [3_600, 3_600])
    }

    /// This phone's id is read once the session is open: a read that starts while it reopens (after the foreground) still
    /// finds this phone, as Android reads it after the list.
    @Test func thisPhoneIsFoundWhenTheSessionOpensDuringTheRead() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try fleet()
        let open = OpenFlag()
        let m = DevicesManager(
            ops: { open.value = true; return ops }, quietOps: { open.value = true; return ops },
            selfID: { open.value ? "me" : nil }, onDeviceGone: { _ in }
        )
        try await m.refresh()
        #expect(m.devices.first?.thisPhone == true && m.devices.first?.id == "me")
    }

    /// `device.list` entries with an unreadable member are skipped one by one, not as a whole.
    @Test func oneBadEntryDoesNotFailTheList() async throws {
        let ops = FakeDevicesOps()
        ops.devices = try obj(#"{"devices":[{"id":"a1","kind":"agent","name":"A","state":7},{"id":"d1","kind":"desktop","name":5,"created_at":"never"},{"kind":"agent"}]}"#)
        let m = manager(ops)
        try await m.refresh()
        #expect(m.devices.map(\.id) == ["a1", "d1"])
        #expect(m.devices[1].name.isEmpty && m.devices[1].createdAt == nil)
    }

    @Test func theDescriptionNeverPrintsAName() throws {
        let d = DeviceInfo(id: "a1", kind: "agent", name: "Secret Agent Name")
        #expect(!"\(d)".contains("Secret") && !String(reflecting: d).contains("Secret") && !"\(Mirror(reflecting: d).children.count)".contains("Secret"))
        #expect(Mirror(reflecting: d).children.isEmpty)
    }
}

private extension Array {
    /// The one element, nil for none or several.
    var single: Element? { count == 1 ? first : nil }
}
// swiftlint:enable line_length
