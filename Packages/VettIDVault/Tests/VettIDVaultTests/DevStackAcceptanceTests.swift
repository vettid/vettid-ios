import Foundation
import Testing
import VettIDAltChan
import VettIDAltChanTesting
import VettIDAttestation
import VettIDCrypto
import VettIDRelay
@testable import VettIDVault

/// IOS-PLAN §8 I1.3's acceptance (the A2-equivalent) against the local dev stack (vettid-vault `cmd/devstack`): on the
/// simulator, with the TEST iOS attester that the dev enclave's TEST policy trusts, a software app key and the
/// stack's TEST-ONLY trust anchors from its control port, enroll a vault through the member API (setup code, PIN,
/// release R's unlock secret), run the first handshake, create the credential and confirm the vault, lock it and
/// unlock it with the PIN, connect to the `vaultctl` peer through an invitation and exchange a message both ways.
/// Mirrors vettid-android `ExitScenario` (its A2 steps without the critical item).
///
/// Skipped unless `VETTID_DEVSTACK=1`: `scripts/devstack-test.sh` starts the stack and runs it
/// (`VETTID_DEVSTACK_API`, `VETTID_DEVSTACK_RELAY`, `VETTID_DEVSTACK_CTL` override the addresses).
///
/// The unlock secret is one fixed random value for this test's vault (VAULT-MESSAGING §11.14): the iPhone's phone key
/// derivation (§11.14.1, VettIDData's `PhoneSecrets`) and the vault manager's unlock (I1.7) are not what this checks.
@Suite(.serialized) struct DevStackAcceptanceTests {
    static let enabled = ProcessInfo.processInfo.environment["VETTID_DEVSTACK"] == "1"
    static let pin = "97531086"
    static let password = "correct horse battery staple (test)"

    @Test(.enabled(if: enabled, "the dev stack test runs with VETTID_DEVSTACK=1 (scripts/devstack-test.sh)"), .timeLimit(.minutes(10)))
    func enrollUnlockAndMessageTheVaultctlPeer() async throws { // swiftlint:disable:this function_body_length
        let stack = DevStack.fromEnvironment()
        try #require(await stack.reachable(), "the dev stack does not answer at \(stack.control)")
        let trust = try await stack.trust()
        let guid = "ios-" + Ulid.new().lowercased()
        // The attester's default form: ED and Apple's extensions map, as a real iPhone sends them on iOS 27.
        let attester = TestIOSAttester()
        let appKey = SoftwareAppKey()
        let generated = try DeviceSecrets.generate()
        let secrets = DeviceSecrets(identity: generated.identity, kem: generated.kem, relay: generated.relay, apiKey: try appKey.spki())
        let verifier = EnclaveVerifier(nitro: NitroVerifier(roots: trust.nitroRoots))
        let cfg = DeviceConfig(
            name: "iPhone test", relayURL: stack.relayURL, transport: stack.transport, store: InMemoryDeviceStateStore(),
            enrolledAttestation: .verify { doc, bundle, nonce, p, now in
                try verifier.verifyEnrolled(
                    attestation: doc, vaultBundle: bundle, nonce: nonce,
                    expected: Measurements(pcr0: p.pcr0, pcr1: p.pcr1, pcr2: p.pcr2), now: now
                )
            },
            pollWait: 10
        )
        let device = try await VaultDevice.create(cfg, secrets: secrets)
        device.start()
        defer { device.stop() }
        let vault = VaultApi(device: device, normalizePasswords: { true })

        // MEMBER-API 2.0.0: the portal issues a setup code; the app redeems it with its app key, which signs every
        // later request.
        let code = try await stack.issueSetupCode(guid: guid)
        let redeemed = try await MemberApiClient(
            apiBase: stack.apiBase, manifestURL: stack.manifestURL, transport: stack.transport, auth: .appKey(appKey) { "" }
        ).redeemSecret(code, appKey: try appKey.spki())
        #expect(redeemed.userGuid == guid)
        let vaultID = redeemed.vaultID
        let member = MemberApiClient(
            apiBase: stack.apiBase, manifestURL: stack.manifestURL, transport: stack.transport, auth: .appKey(appKey) { vaultID }
        )
        let flow = AltChannelFlow(api: member, trust: trust)
        let unlockSecret = Randomness.bytes(32)
        let secretFor: @Sendable ([String]) async throws -> [UInt8]? = { caps in
            caps.contains(Capabilities.recoveryR) ? unlockSecret : nil
        }

        // Enroll (§11.3): PIN, the TEST attestation, then vault.enrolled and the first handshake.
        let enrolled = try await flow.enroll(
            party: device, vaultID: vaultID, userGuid: guid, pin: Self.pin, attester: attester, unlockSecretFor: secretFor
        )
        try #require(enrolled.ok, "enroll refused: \(enrolled.code ?? "")")
        try await device.awaitEnrolled()
        try await device.completeEnrollment()
        #expect(device.deviceID != nil)
        try await vault.credentialCreate(password: Self.password, pin: Self.pin)
        try await vault.enrollConfirm()
        let status = try await vault.status()
        #expect(status.vaultId == vaultID && status.provisional != true)

        // Lock, then unlock with the PIN (§11.4): the TEST attester's assertion, counter 1.
        _ = try await flow.lock(vaultID: vaultID)
        try await waitFor("the vault locked") { try await member.vaultStatus()?.state == "locked" }
        let unlocked = try await flow.unlock(
            party: device, userGuid: guid, pin: Self.pin, attester: attester, unlockSecretFor: secretFor
        )
        try #require(unlocked.ok, "unlock refused: \(unlocked.result.code ?? "")")
        #expect(attester.lastCounter == 1)
        let reopened = try await vault.status()
        #expect(reopened.vaultId == vaultID)

        // Connect to the vaultctl peer through an invitation (§6.4): both sides see the same SAS and approve.
        let invite = VaultJSON.object(try await device.op("connection.invite.create", body: Array(#"{"ttl_seconds":3600}"#.utf8)))
        let link = try invite.string("link")
        let accepted = try await stack.peerRequest("connection.invite.accept", body: JsonBuilder().string("link", link).build())
        let peerConnection = try accepted.string("connection_id")
        let pending = try await vault.awaitEvent("connection.request.pending").object
        let outgoing = try await stack.peerRequestWithSas(direction: "outgoing", connectionID: peerConnection)
        let sas = VaultJSON.string(pending, "sas")
        let peerSas = try outgoing.optString("sas")
        #expect(sas != nil && sas == peerSas)
        let pendingID = try #require(VaultJSON.string(pending, "pending_id"))
        _ = try await device.op("connection.approve", body: JsonBuilder().string("pending_id", pendingID).bytes())
        let known = try await stack.peerActiveConnections()
        try await stack.peerRequest("connection.approve", body: JsonBuilder().string("connection_id", peerConnection).build())
        let added = try await vault.awaitEvent("connection.event") { VaultJSON.string($0.object, "event") == "added" }.object
        let connection = try #require(VaultJSON.string(added, "connection_id"))
        let peerAdded = try await stack.peerAwaitNewConnection(known: known)
        #expect(peerAdded == peerConnection)

        // Messages both ways (§10.5).
        let out = "hello from the iPhone app \(Ulid.new())"
        _ = try await device.op("message.send", body: JsonBuilder().string("connection_id", connection).string("text", out).bytes())
        let got = try await stack.peerEvent("message.new", match: ["text": out])
        #expect(VaultJSON.string(got, "direction") == "in")
        let back = "hello from vaultctl \(Ulid.new())"
        let reply = JsonBuilder().string("connection_id", peerConnection).string("text", back).build()
        try await stack.peerRequest("message.send", body: reply)
        let inbound = try await vault.awaitEvent("message.new") { VaultJSON.string($0.object, "text") == back }.object
        #expect(VaultJSON.string(inbound, "direction") == "in" && VaultJSON.string(inbound, "connection_id") == connection)
        let listBody = JsonBuilder().string("connection_id", connection).bytes()
        let list = VaultJSON.object(try await device.op("message.list", body: listBody))
        let texts = try list.array("messages").map { try $0.asObject().string("text") }
        #expect(texts.contains(out) && texts.contains(back))
    }

    private func waitFor(_ what: String, _ ok: () async throws -> Bool) async throws {
        for _ in 0..<120 {
            if try await ok() { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw DevStackError("timed out waiting for \(what)")
    }
}
