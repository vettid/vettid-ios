import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Event bodies and fixtures stay on one line each.
// swiftlint:disable line_length

/// A credential key of [count] bytes of [n], as base64.
func testKey(_ n: UInt8, count: Int = 32) -> String { Data(repeating: n, count: count).base64EncodedString() }

/// Member authentication as the vault reports it (VAULT-MESSAGING 0.88.1 §10.4): the pinned `key` and the `key_changed`
/// warning from `connection.authenticate.list` and `.result`, and `connection.authenticate.key`. Mirrors vettid-android's
/// `ApprovalParserTest` and `AuthKeyEventTest`. The vault follows rotation chains; the app never sees one.
@MainActor
@Suite struct AuthenticationKeyTests {
    let ops = FakeConnectionOps()
    let now = Date(timeIntervalSince1970: 1_791_115_200)
    let keyA = testKey(1)
    let keyB = testKey(2)

    func manager() -> ConnectionsManager {
        let ops = ops, now = now
        return ConnectionsManager(ops: { ops }, now: { now })
    }

    func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: now, body: Array(body.utf8)))
    }

    func result(_ m: ConnectionsManager, _ body: String) { m.onEvent(event("connection.authenticate.result", body)) }

    func keyEvent(_ m: ConnectionsManager, _ body: String) { m.onEvent(event("connection.authenticate.key", body)) }

    /// A manager that has read connection `c1` and its authentication state (the list's key is [keyA]).
    func loaded() async throws -> ConnectionsManager {
        ops.connections = [ConnectionsManagerTests.connection("c1")]
        ops.authStates = #"{"states":[{"connection_id":"c1","key":"\#(keyA)","verified_at":"2026-10-04T12:00:00Z","last_result":"authenticated","last_at":"2026-10-04T12:00:00Z"}]}"#
        let m = manager()
        try await m.refresh()
        return m
    }

    /// A manager with a standing key-change warning, from a successful verdict.
    func warned() async throws -> ConnectionsManager {
        let m = try await loaded()
        result(m, #"{"connection_id":"c1","request_id":"r1","authenticated":true,"key":"\#(keyB)","key_changed":true}"#)
        #expect(m.authentication["c1"]?.keyChanged == true)
        return m
    }

    // MARK: - The key

    @Test func aKeyIsCanonicalStandardBase64OfThirtyTwoBytes() throws {
        func parsed(_ json: String) throws -> String? { ConnectionParser.credentialKey(try StrictJson.parseObject(json)) }
        #expect(try parsed(#"{"key":"\#(keyA)"}"#) == keyA)
        #expect(try parsed(#"{}"#) == nil)
        for bad in [testKey(1, count: 31), testKey(1, count: 33), "", "not base64!", String(keyA.dropLast()), // no padding
                    keyA + "=", // extra padding
                    String(keyA.dropLast(2)) + "F=", // non-zero trailing bits
                    keyA.replacingOccurrences(of: "Q", with: "-")] { // another alphabet
            #expect(try parsed(#"{"key":"\#(bad)"}"#) == nil, "\(bad)")
        }
        #expect(try parsed(#"{"key":5}"#) == nil)
        #expect(try parsed(#"{"key":{"a":1}}"#) == nil)
    }

    @Test func aListStateCarriesItsTimesResultAndKeyAndAMalformedKeyDropsOnlyTheKey() async throws {
        let m = try await loaded()
        let s = try #require(m.authentication["c1"])
        #expect(s.key == keyA && s.lastResult == "authenticated" && s.verifiedAt != nil && s.lastAt != nil && !s.keyChanged)
        ops.authStates = #"{"states":[{"connection_id":"c1","key":"AAAA","verified_at":"2026-10-05T12:00:00Z","last_result":"denied"}]}"#
        try await m.refresh()
        let t = try #require(m.authentication["c1"])
        #expect(t.key == nil && t.lastResult == "denied" && t.verifiedAt == ConnectionParser.instant("2026-10-05T12:00:00Z"))
    }

    @Test func theStateNeverPrintsTheKeyOrTheConnection() async throws {
        let m = try await loaded()
        let s = try #require(m.authentication["c1"])
        for text in ["\(s)", String(reflecting: s), String(describing: Mirror(reflecting: s).children.map { "\($0)" })] {
            #expect(!text.contains(keyA) && !text.contains("c1"))
        }
    }

    // MARK: - Verdicts

    @Test func aSuccessfulVerdictDecidesTheWarningAndTheKey() async throws {
        let m = try await loaded()
        result(m, #"{"connection_id":"c1","request_id":"r1","authenticated":true,"key":"\#(keyB)","key_changed":true}"#)
        #expect(m.authentication["c1"]?.keyChanged == true && m.authentication["c1"]?.key == keyB)
        #expect(m.authentication["c1"]?.lastResult == "authenticated" && m.authentication["c1"]?.verifiedAt == now)
        // A later success without `key_changed` (or with false) clears it; a missing or bad key keeps the one held.
        result(m, #"{"connection_id":"c1","request_id":"r2","authenticated":true,"key":"AAAA"}"#)
        #expect(m.authentication["c1"]?.keyChanged == false && m.authentication["c1"]?.key == keyB)
    }

    @Test func aSuccessWithoutKeyChangedFalseClearsAndTrueSets() async throws {
        let m = try await loaded()
        result(m, #"{"connection_id":"c1","request_id":"r1","authenticated":true,"key_changed":true}"#)
        #expect(m.authentication["c1"]?.keyChanged == true && m.authentication["c1"]?.key == keyA, "no key: the previous one stays")
        result(m, #"{"connection_id":"c1","request_id":"r2","authenticated":true,"key_changed":false}"#)
        #expect(m.authentication["c1"]?.keyChanged == false)
    }

    /// The party a key-change warning is about must not be able to erase it by declining the member's next request.
    @Test(arguments: [
        #"{"connection_id":"c1","request_id":"r2","authenticated":false,"reason":"denied"}"#,
        #"{"connection_id":"c1","request_id":"r2","authenticated":false,"reason":"bad_signature"}"#,
        #"{"connection_id":"c1","request_id":"r2","authenticated":false,"key_changed":false,"key":"\#(testKey(3))"}"#,
        #"{"connection_id":"c1","request_id":"r2","key_changed":false,"key":"\#(testKey(3))"}"#, // no `authenticated`: not a success
        #"{"connection_id":"c1","request_id":"r2","authenticated":"true","key_changed":false}"#, // not a boolean
    ])
    func aFailedVerdictKeepsTheWarningAndTheKey(_ body: String) async throws {
        let m = try await warned()
        result(m, body)
        #expect(m.authentication["c1"]?.keyChanged == true)
        #expect(m.authentication["c1"]?.key == keyB)
        #expect(m.authentication["c1"]?.verifiedAt == now, "a failure verifies nothing new")
        #expect(m.authentication["c1"]?.lastResult != "authenticated")
    }

    @Test func aFailedVerdictMakesNoWarningAndTakesNoKeyOfItsOwn() async throws {
        let m = try await loaded()
        result(m, #"{"connection_id":"c1","request_id":"r","authenticated":false,"reason":"bad_signature","key_changed":true,"key":"\#(keyB)"}"#)
        #expect(m.authentication["c1"]?.keyChanged == false && m.authentication["c1"]?.key == keyA)
        #expect(m.authentication["c1"]?.lastResult == "bad_signature")
    }

    @Test func aVerdictWithoutAConnectionIdIsIgnored() async throws {
        let m = try await loaded()
        let before = m.authentication
        result(m, #"{"request_id":"r","authenticated":true,"key_changed":true}"#)
        #expect(m.authentication == before)
    }

    @Test func aVerdictIsBuiltFromTheStateHeldNowSoAListReadBeforeItIsNotUndone() async throws {
        let m = try await loaded()
        result(m, #"{"connection_id":"c1","request_id":"r","authenticated":true,"key":"\#(keyB)","key_changed":true}"#)
        ops.authStates = #"{"states":[{"connection_id":"c1","key":"\#(keyB)","last_result":"authenticated"}]}"#
        try await m.refresh()
        #expect(m.authentication["c1"]?.keyChanged == true, "the list has no key_changed: it is carried over")
    }

    // MARK: - connection.authenticate.key

    @Test func aKeyEventDoesNotClearAStandingWarning() async throws {
        let m = try await warned()
        ops.authStates = #"{"states":[{"connection_id":"c1","key":"\#(keyB)"}]}"#
        keyEvent(m, #"{"connection_id":"c1","key":"\#(keyB)"}"#)
        #expect(await eventually { !m.keyRereadRunning && ops.authCalls == 2 })
        #expect(m.authentication["c1"]?.keyChanged == true)
        // And a verdict after it decides again.
        keyEvent(m, #"{"connection_id":"c1","key":"\#(keyA)"}"#)
        result(m, #"{"connection_id":"c1","request_id":"r","authenticated":true,"key_changed":true}"#)
        #expect(await eventually { !m.keyRereadRunning })
        #expect(m.authentication["c1"]?.keyChanged == true)
        result(m, #"{"connection_id":"c1","request_id":"r2","authenticated":true,"key_changed":false}"#)
        #expect(m.authentication["c1"]?.keyChanged == false)
    }

    @Test func aKeyChangeAfterAKeyEventIsShown() async throws {
        let m = try await loaded()
        keyEvent(m, #"{"connection_id":"c1","key":"\#(keyB)"}"#)
        #expect(await eventually { !m.keyRereadRunning && ops.authCalls == 2 })
        #expect(m.authentication["c1"]?.keyChanged == false)
        result(m, #"{"connection_id":"c1","request_id":"r","authenticated":true,"key_changed":true}"#)
        #expect(m.authentication["c1"]?.keyChanged == true)
    }

    @Test func aKeyEventReadsBothListsAndTheListDecidesTheKeyNotTheEvent() async throws {
        let m = try await loaded()
        let reads = ops.calls.filter { $0 == "list" }.count
        ops.authStates = #"{"states":[{"connection_id":"c1","key":"\#(keyB)","last_result":"authenticated"}]}"#
        ops.connections = [ConnectionsManagerTests.connection("c1"), ConnectionsManagerTests.connection("c2")]
        keyEvent(m, #"{"connection_id":"c1","key":"\#(testKey(9))"}"#)
        #expect(await eventually { m.connections.count == 2 && m.authentication["c1"]?.key == keyB })
        #expect(ops.calls.filter { $0 == "list" }.count == reads + 1 && ops.authCalls == 2)
        #expect(m.authentication["c1"]?.key != testKey(9), "the event's key is never written")
    }

    @Test(arguments: [
        #"{}"#, #"{"connection_id":"c1"}"#, #"{"key":"\#(testKey(1))"}"#,
        #"{"connection_id":"c1","key":"AAAA"}"#, #"{"connection_id":"c1","key":""}"#, #"{"connection_id":"c1","key":5}"#,
        #"{"connection_id":5,"key":"\#(testKey(1))"}"#,
        #"{"connection_id":"c1","key":"\#(testKey(1, count: 31))"}"#,
        #"{"connection_id":"c1","key":"\#(testKey(1, count: 33))"}"#,
    ])
    func aMalformedKeyEventIsIgnoredAndMakesNoRead(_ body: String) async throws {
        let m = try await loaded()
        let (listReads, authReads, before) = (ops.calls.count, ops.authCalls, m.authentication)
        keyEvent(m, body)
        #expect(!m.keyRereadRunning)
        try await Task.sleep(for: .milliseconds(50))
        #expect(ops.calls.count == listReads && ops.authCalls == authReads && m.authentication == before)
    }

    /// A lock, a hold or a wipe since the event writes nothing of what was read (IOS-PLAN §6.9).
    @Test func aStaleEpochWritesNothing() async throws {
        let m = try await loaded()
        ops.connections = [ConnectionsManagerTests.connection("c1"), ConnectionsManagerTests.connection("c2")]
        m.keyRereadHook = { m.forgetOpenVault() }
        keyEvent(m, #"{"connection_id":"c1","key":"\#(keyB)"}"#)
        #expect(await eventually { !m.keyRereadRunning })
        #expect(ops.authCalls == 2, "the read was made")
        #expect(m.connections.isEmpty && m.authentication.isEmpty)
    }

    @Test func aLockBeforeTheJobRunsWritesNothingEither() async throws {
        let m = try await loaded()
        keyEvent(m, #"{"connection_id":"c1","key":"\#(keyB)"}"#)
        m.forgetOpenVault() // before the job's first suspension: the event's generation is stale
        #expect(await eventually { !m.keyRereadRunning })
        #expect(m.connections.isEmpty && m.authentication.isEmpty)
    }

    @Test func aFailedReadWritesNothingWhicheverHalfFailed() async throws {
        let m = try await warned()
        let before = (m.connections, m.authentication)
        ops.connections = [ConnectionsManagerTests.connection("c1"), ConnectionsManagerTests.connection("c2")]
        ops.authStates = #"{"states":[{"connection_id":"c1","key":"\#(keyB)"}]}"#
        // The state list fails (another failure than the vault's refusal): the connections it came with are not taken in.
        ops.authError = URLError(.notConnectedToInternet)
        keyEvent(m, #"{"connection_id":"c1","key":"\#(keyB)"}"#)
        #expect(await eventually { !m.keyRereadRunning && ops.authCalls == 2 })
        #expect(m.connections == before.0 && m.authentication == before.1)
        // The vault refuses the state list: no states, nothing written either.
        ops.authError = FakeConnectionOps.error("connection.authenticate.list", "unknown_type")
        keyEvent(m, #"{"connection_id":"c1","key":"\#(keyB)"}"#)
        #expect(await eventually { !m.keyRereadRunning && ops.authCalls == 3 })
        #expect(m.connections == before.0 && m.authentication == before.1)
        // The connection list fails.
        ops.authError = nil
        ops.errors["list"] = FakeConnectionOps.error("connection.list", "retry")
        keyEvent(m, #"{"connection_id":"c1","key":"\#(keyB)"}"#)
        #expect(await eventually { !m.keyRereadRunning && ops.errors["list"] == nil })
        #expect(m.connections == before.0 && m.authentication == before.1)
        // A later event reads again (the slot was freed).
        keyEvent(m, #"{"connection_id":"c1","key":"\#(keyB)"}"#)
        #expect(await eventually { m.connections.count == 2 })
    }

    @Test func aBurstOfEventsCostsAtMostTwoReadsAndTheLastReadStartsAfterTheLastEvent() async throws {
        let m = try await loaded()
        let gate = TestDeferred<Void>()
        ops.authGate = gate
        for _ in 0..<20 { keyEvent(m, #"{"connection_id":"c1","key":"\#(keyB)"}"#) }
        #expect(await eventually { ops.authCalls == 2 }, "one running (the first call) ...")
        ops.authStates = #"{"states":[{"connection_id":"c1","key":"\#(keyB)"}]}"#
        gate.complete(())
        #expect(await eventually { !m.keyRereadRunning })
        #expect(ops.authCalls == 3, "... and one more, not twenty (the loaded manager's own read was the first)")
        #expect(m.authentication["c1"]?.key == keyB)
    }

    @Test func aReadInFlightDoesNotHoldUpOtherEvents() async throws {
        let m = try await loaded()
        let gate = TestDeferred<Void>()
        ops.authGate = gate
        defer { gate.complete(()) }
        keyEvent(m, #"{"connection_id":"c1","key":"\#(keyB)"}"#)
        #expect(await eventually { m.keyRereadRunning && ops.authCalls == 2 })
        result(m, #"{"connection_id":"c1","request_id":"r","authenticated":true,"key_changed":true}"#)
        #expect(m.authentication["c1"]?.keyChanged == true)
        m.onEvent(event("connection.event", #"{"connection_id":"c1","event":"removed"}"#))
        #expect(m.authentication["c1"] == nil, "taken in at once")
    }

    // MARK: - Verdicts that land while a read is in flight

    /// A verdict taken in while a re-read waits is not undone by the read: the state is built at the write.
    @Test(arguments: [true, false])
    func aVerdictDuringAKeyRereadSurvivesIt(_ changed: Bool) async throws {
        let m = changed ? try await loaded() : try await warned()
        let gate = TestDeferred<Void>()
        ops.authGate = gate
        keyEvent(m, #"{"connection_id":"c1","key":"\#(keyB)"}"#)
        #expect(await eventually { m.keyRereadRunning && ops.authCalls == 2 })
        result(m, #"{"connection_id":"c1","request_id":"r","authenticated":true,"key_changed":\#(changed)}"#)
        gate.complete(())
        #expect(await eventually { !m.keyRereadRunning })
        #expect(m.authentication["c1"]?.keyChanged == changed)
    }

    @Test(arguments: [true, false])
    func aVerdictDuringARefreshSurvivesIt(_ changed: Bool) async throws {
        let m = changed ? try await loaded() : try await warned()
        let gate = TestDeferred<Void>()
        ops.authGate = gate
        let reading = Task { try await m.refresh() }
        #expect(await eventually { ops.authCalls == 2 })
        result(m, #"{"connection_id":"c1","request_id":"r","authenticated":true,"key_changed":\#(changed)}"#)
        gate.complete(())
        try await reading.value
        #expect(m.authentication["c1"]?.keyChanged == changed)
    }

    /// Present but not a boolean decides nothing (fails closed); absent is false (§10.4).
    @Test(arguments: [#""key_changed":"false""#, #""key_changed":0"#, #""key_changed":null"#, #""key_changed":{}"#])
    func aKeyChangedThatIsNotABooleanKeepsTheHeldValue(_ member: String) async throws {
        let m = try await warned()
        result(m, #"{"connection_id":"c1","request_id":"r","authenticated":true,\#(member)}"#)
        #expect(m.authentication["c1"]?.keyChanged == true)
        let n = try await loaded()
        result(n, #"{"connection_id":"c1","request_id":"r","authenticated":true,\#(member)}"#)
        #expect(n.authentication["c1"]?.keyChanged == false, "nothing was held, nothing is made up")
        result(m, #"{"connection_id":"c1","request_id":"r","authenticated":true}"#)
        #expect(m.authentication["c1"]?.keyChanged == false, "absent: false")
    }

    // MARK: - A hold

    /// A hold (§3.6.3) drops the connections but keeps the authentication states and the warning; a read begun before it
    /// is not published (the generation moved), and the read after it takes the states in again.
    @Test func aHoldKeepsTheWarningAndAReadBeforeItWritesNothing() async throws {
        let m = try await warned()
        ops.authStates = #"{"states":[{"connection_id":"c1","key":"\#(testKey(7))"}]}"#
        m.keyRereadHook = { m.forgetOpenVault(keepingAuthentication: true) }
        keyEvent(m, #"{"connection_id":"c1","key":"\#(keyB)"}"#)
        #expect(await eventually { !m.keyRereadRunning })
        #expect(m.connections.isEmpty, "the connections went at the hold")
        #expect(m.authentication["c1"]?.keyChanged == true && m.authentication["c1"]?.key == keyB, "kept, and the stale read not written")
        m.keyRereadHook = nil
        try await m.refresh()
        #expect(m.authentication["c1"]?.keyChanged == true && m.authentication["c1"]?.key == testKey(7))
    }

    @Test func aLockAWipeAndAForgetStillDropTheStatesAfterAHold() async throws {
        let m = try await warned()
        m.forgetOpenVault(keepingAuthentication: true)
        #expect(m.authentication["c1"]?.keyChanged == true)
        m.forgetAuthentication()
        #expect(m.authentication.isEmpty)
        let n = try await warned()
        n.forgetOpenVault(keepingAuthentication: true)
        n.clear()
        #expect(n.authentication.isEmpty)
    }

    @Test func aStateKeptAcrossAHoldForAConnectionRemovedMeanwhileGoesAtTheNextRead() async throws {
        let m = try await warned()
        m.forgetOpenVault(keepingAuthentication: true)
        ops.connections = []
        try await m.refresh()
        #expect(m.authentication.isEmpty)
    }

    // MARK: - Dropped

    @Test func theStateGoesAtALockAWipeARemovalAndAForget() async throws {
        let m = try await warned()
        m.forgetOpenVault()
        #expect(m.authentication.isEmpty)
        let n = try await warned()
        n.onEvent(event("connection.event", #"{"connection_id":"c1","event":"removed"}"#))
        #expect(n.authentication["c1"] == nil)
        let o = try await warned()
        try await o.remove("c1")
        #expect(o.authentication["c1"] == nil)
        let p = try await warned()
        p.clear()
        #expect(p.authentication.isEmpty)
    }

    @Test func aConnectionRemovedOnAnotherDeviceTakesItsStateWithIt() async throws {
        let m = try await warned()
        ops.connections = []
        ops.authStates = #"{"states":[]}"#
        try await m.refresh()
        #expect(m.connections.isEmpty && m.authentication["c1"] == nil)
    }

    // MARK: - The refresh

    @Test func aRefusedStateListLeavesTheConnectionsAndNoFailureAndAnotherFailureThrowsAfterThem() async throws {
        ops.connections = [ConnectionsManagerTests.connection("c1")]
        let m = manager()
        ops.authError = FakeConnectionOps.error("connection.authenticate.list", "unknown_type")
        try await m.refresh()
        #expect(m.connections.count == 1 && m.authentication.isEmpty)
        ops.authError = URLError(.notConnectedToInternet)
        ops.connections.append(ConnectionsManagerTests.connection("c2"))
        await #expect(throws: VaultFailure.self) { try await m.refresh() }
        #expect(m.connections.count == 2, "the connections were taken in first")
    }
}

// swiftlint:enable line_length
