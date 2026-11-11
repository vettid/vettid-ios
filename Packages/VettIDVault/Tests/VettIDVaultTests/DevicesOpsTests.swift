import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// Deposits counted from the relay's hook (any thread).
final class DepositCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// The requests of "Devices & agents" (ANDROID-PLAN 0.1.53 AA1 and AA2; VAULT-MESSAGING §10.3, §10.11) on the wire against the fake
/// vault: the member names of each body, and no `session_id` or `agent_id` where none is meant. Mirrors vettid-android
/// `VaultDeviceTest`'s devices test.
@Suite struct DevicesOpsTests {
    let ops = CredentialOpsTests()

    func body(_ req: Inner) -> String { String(bytes: req.body, encoding: .utf8) ?? "" }

    @Test func endingAccessAndUnlinkingNameTheDeviceAlone() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let end = Task { try await api.sessionEnd(deviceID: "a1") }
        var req = try await ops.answer(v, d, "device.session.end", "{}")
        #expect(body(req) == #"{"device_id":"a1"}"#)
        try await end.value
        let unlink = Task { try await api.deviceUnlink("d1") }
        req = try await ops.answer(v, d, "device.unlink", "{}")
        #expect(body(req) == #"{"device_id":"d1"}"#)
        try await unlink.value
    }

    @Test func theGrantListNamesTheAgentOnlyWhenAsked() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let one = Task { try await api.leashGrantList(agentID: "a2") }
        var req = try await ops.answer(v, d, "leash.grant.list", #"{"grants":[{"grant_id":"g1","status_ttl":300}],"suspended":[]}"#)
        #expect(body(req) == #"{"agent_id":"a2"}"#)
        #expect(try await one.value.array("grants").count == 1)
        let all = Task { try await api.leashGrantList() }
        req = try await ops.answer(v, d, "leash.grant.list", #"{"grants":[],"suspended":["a1"]}"#)
        // No `agent_id` key at all, and nothing else.
        #expect(body(req) == "{}")
        #expect(try await all.value.array("suspended").count == 1)
    }

    /// The raw list keeps an entry the strict decoding would refuse, and `profile`.
    @Test func theRawListKeepsWhatTheStrictListRefuses() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let list = Task { try await api.deviceListBody() }
        let req = try await ops.answer(v, d, "device.list", #"{"devices":[{"id":"a1","kind":"agent","profile":{"name":"Claude"}},{"kind":"agent","state":7}]}"#)
        #expect(body(req) == "{}")
        let devices = try await list.value.array("devices")
        #expect(devices.count == 2)
    }

    /// "Pair a desktop" (owner decision 2026-11-05; VAULT-MESSAGING §10.3): `device.pair.create` carries exactly the role, and
    /// `device.pair.approve` the pairing and the first session, never `grants`. Mirrors vettid-android `VaultDeviceTest`'s
    /// `pairingRequestsCarryTheRoleAndNoGrants`.
    @Test func pairingRequestsCarryTheRoleAndNoGrants() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let created = #"{"pairing_id":"p1","link":"L","exp":"2026-10-26T12:10:00Z"}"#

        let desktop = Task { try await api.devicePairCreate(role: "desktop") }
        var req = try await ops.answer(v, d, "device.pair.create", created)
        #expect(body(req) == #"{"role":"desktop"}"#)
        // The answer is returned as the vault sent it, for the caller to read.
        #expect(try await desktop.value.string("pairing_id") == "p1")

        let agent = Task { try await api.devicePairCreate(role: "agent") }
        req = try await ops.answer(v, d, "device.pair.create", created)
        #expect(body(req) == #"{"role":"agent"}"#)
        _ = try await agent.value

        let timed = Task { try await api.pairApprove("p1", sessionSeconds: 3600) }
        req = try await ops.answer(v, d, "device.pair.approve")
        #expect(body(req) == #"{"pairing_id":"p1","session_seconds":3600}"#)
        try await timed.value

        let none = Task { try await api.pairApprove("p1", sessionSeconds: nil) }
        req = try await ops.answer(v, d, "device.pair.approve")
        #expect(body(req) == #"{"pairing_id":"p1"}"#)
        try await none.value

        let reject = Task { try await api.pairReject("p1") }
        req = try await ops.answer(v, d, "device.pair.reject")
        #expect(body(req) == #"{"pairing_id":"p1"}"#)
        try await reject.value
    }

    /// Only an agent or a desktop: an app is a transfer (§6.7.1) and never created here; nothing is sent.
    @Test func aPairingOfAnyOtherRoleIsRefusedAndNothingIsSent() async throws {
        let (d, _) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let sent = DepositCounter()
        ops.base.relay.onDeposit = { sent.add() }
        for role in ["app", "", "Agent", "agent "] {
            await #expect(throws: VaultStateError.self) { try await api.devicePairCreate(role: role) }
        }
        #expect(sent.value == 0)
    }
}
// swiftlint:enable line_length
