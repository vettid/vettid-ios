import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The requests of "Devices & agents" (ANDROID-PLAN 0.1.53 AA1; VAULT-MESSAGING §10.3, §10.11) on the wire against the fake
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
}
