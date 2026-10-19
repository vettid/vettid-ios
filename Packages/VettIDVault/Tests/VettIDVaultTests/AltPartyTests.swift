import CryptoKit
import Foundation
import Testing
@testable import VettIDVault
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDRelay

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// VaultDevice as the alternate channel's party (§11.4): the unlock it builds (its standing token for the vault, the
/// rollback floors, the identity signature) and the result it applies (the floors, the vault's fresh token).
@Suite struct AltPartyTests {
    let relay = FakeRelay()

    struct Attest: Attester {
        func attest(_ challenge: [UInt8]) throws -> DeviceAttest { try DeviceAttest.androidChain([[1]]) }
        func assert(_ signed: AttestSigned) throws -> DeviceAssertion { try DeviceAssertion.androidSignature([2]) }
    }

    static let pcr0 = String(repeating: "a3", count: 48)

    func manifest() throws -> ReleaseManifest {
        let key = P256.Signing.PrivateKey()
        let entry = JsonBuilder().uint("release", 3).string("pcr0", Self.pcr0).string("pcr1", String(repeating: "11", count: 48)).string("pcr2", String(repeating: "22", count: 48)).string("seal_key", "arn:aws:kms:us-east-1:000000000000:key/test").string("status", "active").string("published_at", "2026-09-01T00:00:00Z").string("notes", "https://vettid.org/releases/3").build()
        let m = JsonBuilder().uint("v", 1).uint("serial", 7).string("issued_at", "2026-10-02T12:00:00Z").raw("releases", JsonBuilder.array([entry])).bytes()
        let sig = try key.signature(for: Array(ReleaseManifest.label.utf8) + [0] + m).rawRepresentation
        let mk = try ManifestKey(spki: Array(key.publicKey.derRepresentation))
        return try ManifestVerifier(pinned: [mk]).verify(JsonBuilder().base64("manifest", m).base64("sig", Array(sig)).string("key_id", mk.keyID).bytes())
    }

    @Test func anUnlockIsBuiltAndItsResultApplied() async throws {
        let cfg = DeviceConfig(name: "phone", relayURL: relay.baseURL, transport: HTTPTransport(session: relay.server.session, sleep: { _ in }), store: InMemoryDeviceStateStore(), enrolledAttestation: .skipForTests, requestTimeout: 5)
        let d = try await VaultDevice.create(cfg, secrets: try DeviceSecrets.generate())
        let v = try FakeVault(relayURL: relay.baseURL)
        try await d.handle(try v.enrolled(d))
        try await d.awaitEnrolled(timeout: 1)
        let m = try manifest()
        let etk = try KemPrivateKey.generate()
        let desc = try Descriptor.parse(Descriptor.marshal(instanceID: "inst-a", etk: etk.publicKey, release: Self.pcr0, notAfter: Date().addingTimeInterval(3600)))
        let r = try #require(m.byNumber(3))
        let enclave = VerifiedEnclave(descriptor: desc, measurements: r.measurements, release: r)
        let built = try await d.prepareUnlock(userGuid: "guid-1", pin: "246802", enclave: enclave, manifest: m, attester: Attest(), options: UnlockOptions())
        #expect(!built.releaseChanged && built.pending.number == 3)
        // The enclave's view: the request names this device and carries a standing token the vault can deposit with.
        let (padded, _) = try Envelope.openSealed(try Envelope.parse(built.request.envelope), key: etk)
        let body = try StrictJson.parseObject(try Inner.parse(try Padding.unpadFixed(padded, Padding.altChannelRequest), .sealed).body)
        #expect(try body.string("user_guid") == "guid-1" && body.string("vault_id") == v.vaultID && body.string("pin") == "246802")
        let tok = try DepositTokens.verify(try body.string("token"), issuer: d.relayAddr.pk)
        #expect(tok.sub == RelayAuth.encodeKey(v.relayKey.publicKey) && tok.scope == TokenClaims.scopeDeposit)
        // The result, sealed to the device: the floors move up and the vault's fresh token is kept.
        let fresh = try v.token(for: d)
        let result = #"{"ok":true,"state_seq":5,"header_seq":3,"token":"\#(fresh)","release":"\#(Self.pcr0)","release_number":3,"release_status":"active","manifest_serial":7}"#
        let inner = Inner(id: Ulid.new(), type: AltResults.typeUnlockResult, ts: Date(), re: built.request.requestID, status: Inner.statusOK, body: Array(result.utf8))
        let raw = try Envelope.sealSealed(d.kemKey, senderKid: Kid.anonymous, padded: try Padding.padFixed(try inner.marshal(.sealed), Padding.altChannel)).0
        let out = try await d.openUnlockResult(raw)
        #expect(out.ok && out.at != nil)
        #expect(d.altState.stateSeq == 5 && d.altState.headerSeq[Self.pcr0] == 3 && d.altState.manifestSerial == 7 && d.altState.releaseNumber == 3)
        // A second result for the same unlock finds nothing pending.
        await #expect(throws: VaultStateError.self) { _ = try await d.openUnlockResult(raw) }

        // §11.7.1: signer_refused makes the next unlock carry the chain again.
        try await d.markSignerSeen(true)
        let again = try await d.prepareUnlock(userGuid: "guid-1", pin: "246802", enclave: enclave, manifest: m, attester: Attest(), options: UnlockOptions())
        let refused = Inner(id: Ulid.new(), type: AltResults.typeUnlockResult, ts: Date(), re: again.request.requestID, status: Inner.statusOK, body: Array(#"{"ok":false,"code":"signer_refused","header_seq":3}"#.utf8))
        _ = try await d.openUnlockResult(try Envelope.sealSealed(d.kemKey, senderKid: Kid.anonymous, padded: try Padding.padFixed(try refused.marshal(.sealed), Padding.altChannel)).0)
        #expect(!d.signerSeen)

        // A result from another release does not apply, and still ends the pending unlock.
        let third = try await d.prepareUnlock(userGuid: "guid-1", pin: "246802", enclave: enclave, manifest: m, attester: Attest(), options: UnlockOptions())
        let wrong = #"{"ok":true,"state_seq":6,"header_seq":3,"release":"\#(String(repeating: "c5", count: 48))","release_number":4,"release_status":"active","manifest_serial":7}"#
        let wrongInner = Inner(id: Ulid.new(), type: AltResults.typeUnlockResult, ts: Date(), re: third.request.requestID, status: Inner.statusOK, body: Array(wrong.utf8))
        let wrongRaw = try Envelope.sealSealed(d.kemKey, senderKid: Kid.anonymous, padded: try Padding.padFixed(try wrongInner.marshal(.sealed), Padding.altChannel)).0
        await #expect(throws: AltResultFailure.self) { _ = try await d.openUnlockResult(wrongRaw) }
        await #expect(throws: VaultStateError.self) { _ = try await d.openUnlockResult(wrongRaw) }
        #expect(d.altState.stateSeq == 5)
    }

    /// (VAULT-MESSAGING §11.14.9 step 2) An unlock built and then held back before its post leaves the device as before
    /// the build: no pending unlock, the standing token's recorded expiry restored, in memory and in the store.
    @Test func anUnlockAbandonedBeforeItsPostLeavesNothingBehind() async throws {
        let store = InMemoryDeviceStateStore()
        let cfg = DeviceConfig(name: "phone", relayURL: relay.baseURL, transport: HTTPTransport(session: relay.server.session, sleep: { _ in }), store: store, enrolledAttestation: .skipForTests, requestTimeout: 5)
        let d = try await VaultDevice.create(cfg, secrets: try DeviceSecrets.generate())
        let v = try FakeVault(relayURL: relay.baseURL)
        try await d.handle(try v.enrolled(d))
        try await d.awaitEnrolled(timeout: 1)
        let m = try manifest()
        let desc = try Descriptor.parse(Descriptor.marshal(instanceID: "inst-a", etk: try KemPrivateKey.generate().publicKey, release: Self.pcr0, notAfter: Date().addingTimeInterval(3600)))
        let r = try #require(m.byNumber(3))
        let enclave = VerifiedEnclave(descriptor: desc, measurements: r.measurements, release: r)
        d.mem.withLock { d.st.issuedExpMs = 1_000 }
        func saved() throws -> Int64 { try JSONDecoder().decode(DeviceState.self, from: Data(try #require(store.load()))).issuedExpMs }
        let built = try await d.prepareUnlock(userGuid: "guid-1", pin: "246802", enclave: enclave, manifest: m, attester: Attest(), options: UnlockOptions())
        #expect(d.mem.withLock { d.st.issuedExpMs } > 1_000 && d.mem.withLock { d.pendingUnlock } == built.pending)
        #expect(try saved() > 1_000)
        await d.abandonPreparedUnlock(built)
        #expect(d.mem.withLock { d.st.issuedExpMs } == 1_000 && d.mem.withLock { d.pendingUnlock } == nil)
        #expect(try saved() == 1_000)
        // Only the unlock last built: an older one changes nothing.
        let next = try await d.prepareUnlock(userGuid: "guid-1", pin: "246802", enclave: enclave, manifest: m, attester: Attest(), options: UnlockOptions())
        await d.abandonPreparedUnlock(built)
        #expect(d.mem.withLock { d.pendingUnlock } == next.pending && d.mem.withLock { d.st.issuedExpMs } > 1_000)
    }
}

// swiftlint:enable line_length
