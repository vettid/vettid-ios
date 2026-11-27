import Foundation
import Testing
import VettIDCrypto
@testable import VettIDCalls
@testable import VettIDVault

/// (C2) Starts against a C2 vault: form 2 names the connection's key, no call without it, and a form 2 start refused
/// `bad_request` is placed once more after both keys are refreshed (VAULT-MESSAGING §10.10 "Signed key-exchange shares").
/// Port of the cases of vettid-android `VaultCallSignallingTest` for #448.
extension VaultCallSignallingTests {
    static let key7 = [UInt8](repeating: 7, count: 32)
    static let key8 = [UInt8](repeating: 8, count: 32)

    /// The connection shown by [shown]'s fingerprint, its key given by [key] (the same record unless a test changes one).
    func c2Signalling(key: @escaping () -> [UInt8]? = { key7 }, shown: [UInt8] = key7) async -> VaultCallSignalling {
        identities["conn-1"] = try? IkFingerprint.format(shown)
        let s = VaultCallSignalling(
            gateway: gateway, pinned: { [unowned self] in identities[$0] }, suites: [s1],
            refreshConnections: { [unowned self] in
                refreshes += 1
                onRefresh()
            },
            peerKey: { _ in key() }, vaultIsC2: { true }, clock: clock
        )
        listen(s)
        await clock.runCurrent()
        return s
    }

    func badRequest() -> VaultOpError { VaultOpError(type: "error", code: "bad_request", detail: "", body: nil) }

    var starts: [String] { gateway.asked.filter { $0.hasPrefix("start(") } }

    @Test func aC2StartNamesTheConnectionsKeyAndWithoutItNothingIsPlaced() async throws {
        let s = await c2Signalling()
        gateway.startResult = { [unowned self] in try outgoingCall($0, pinned: $1) }
        _ = try await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1])
        #expect(starts == ["start(conn-1, [1], ik 32)"])

        gateway.asked.removeAll()
        let none = await c2Signalling(key: { nil })
        await #expect(throws: CallSecurityError.self) { _ = try await none.start(connectionId: "conn-1", sdp: "v=0", suites: [s1]) }
        #expect(starts.isEmpty, "nothing sent")
    }

    /// The key and the fingerprint the call is pinned to are of one record: a key that is not the one shown places no call.
    @Test func aKeyThatIsNotTheOneShownPlacesNoCall() async throws {
        let s = await c2Signalling(key: { Self.key8 }, shown: Self.key7)
        gateway.startResult = { [unowned self] in try outgoingCall($0, pinned: $1) }
        await #expect(throws: CallSecurityError.self) { _ = try await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1]) }
        #expect(starts.isEmpty, "nothing sent")
    }

    /// The connection's key rotated during the first start: the second start names the new key and is pinned to its new
    /// fingerprint, both read again after the refresh.
    @Test func aFormTwoStartRefusedBadRequestIsPlacedOnceMoreWithTheKeysRefreshed() async throws {
        var key = Self.key7
        let s = await c2Signalling(key: { key })
        onRefresh = { [unowned self] in
            key = Self.key8
            identities["conn-1"] = try? IkFingerprint.format(Self.key8)
        }
        var tries = 0
        var pinnedAt: [String] = []
        gateway.startResult = { [unowned self] in
            tries += 1
            pinnedAt.append($1)
            if tries == 1 { throw badRequest() }
            return try outgoingCall($0, pinned: $1)
        }
        let placed = try await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1], wanted: { true })
        #expect(placed.callId == callId)
        #expect(starts == ["start(conn-1, [1], ik 32)", "start(conn-1, [1], ik 32)"], "once more, in form 2 again")
        #expect(refreshes == 1, "the connections read again for the connection's key")
        #expect(pinnedAt == [try IkFingerprint.format(Self.key7), try IkFingerprint.format(Self.key8)], "pinned to the new key")
    }

    @Test func aSecondRefusalEndsTheCallAsTheFirstWouldHave() async throws {
        let s = await c2Signalling()
        gateway.startResult = { [unowned self] _, _ in throw badRequest() }
        do {
            _ = try await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1], wanted: { true })
            Issue.record("expected a refusal")
        } catch let e as CallRefusedError {
            #expect(e.code == "bad_request")
        }
        #expect(starts.count == 2, "never a third")
    }

    @Test func noReplaceForAnotherRefusalOrAFormOneStart() async throws {
        let s = await c2Signalling()
        gateway.startResult = { _, _ in throw VaultOpError(type: "error", code: "busy", detail: "", body: nil) }
        await #expect(throws: CallRefusedError.self) {
            _ = try await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1], wanted: { true })
        }
        #expect(starts.count == 1)
        #expect(refreshes == 0)

        gateway.asked.removeAll()
        let s10 = await signalling()
        gateway.startResult = { [unowned self] _, _ in throw badRequest() }
        await #expect(throws: CallRefusedError.self) {
            _ = try await s10.start(connectionId: "conn-1", sdp: "v=0", suites: [s1], wanted: { true })
        }
        #expect(starts == ["start(conn-1, [1])"], "a form 1 start is not placed again")
    }

    /// A hang-up or a lock while the first start was out: nothing more is placed, before or after the refresh.
    @Test func aCallNoLongerWantedIsNotPlacedAgain() async throws {
        for after in [false, true] {
            gateway.asked.removeAll()
            var wanted = true
            onRefresh = { if after { wanted = false } }
            let s = await c2Signalling()
            gateway.startResult = { [unowned self] _, _ in
                if !after { wanted = false }
                throw badRequest()
            }
            await #expect(throws: CallRefusedError.self) {
                _ = try await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1], wanted: { wanted })
            }
            #expect(starts.count == 1, "no second start (wanted lost \(after ? "during" : "before") the refresh)")
            #expect(refreshes == (after ? 1 : 0), "a call no longer wanted is not even refreshed for")
            refreshes = 0
        }
    }

    /// The connection's key gone after the refresh: no call at all, never one in form 1.
    @Test func aKeyGoneAfterTheRefreshPlacesNoCall() async throws {
        var key: [UInt8]? = [UInt8](repeating: 7, count: 32)
        onRefresh = { key = nil }
        let s = await c2Signalling(key: { key })
        gateway.startResult = { [unowned self] _, _ in throw badRequest() }
        await #expect(throws: CallSecurityError.self) {
            _ = try await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1], wanted: { true })
        }
        #expect(starts.count == 1)
    }
}
