import Foundation
import Testing
import VettIDAltChan
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// `vault.enrolled` (VAULT-MESSAGING §11.3) for a request whose answer was lost: a retry of the same enrollment built a
/// new request with a new nonce, and the vault's late `vault.enrolled` for the first one is still accepted; a nonce of
/// no request of this enrollment is not; an abandoned enrollment accepts none.
@Suite struct EnrollAttemptsTests {
    let base = VaultDeviceTests()
    static let pcrs = String(repeating: "a3", count: 48) + String(repeating: "11", count: 48) + String(repeating: "22", count: 48)

    /// The test's attestation check: the "document" is the nonce it answers.
    static let check: EnrolledAttestation = .verify { doc, _, nonce, _, _ in
        guard doc == nonce else { throw VaultStateError(message: "nonce") }
    }

    /// vault.enrolled carrying [doc] as its attestation.
    func enrolled(_ v: FakeVault, _ d: VaultDevice, doc: [UInt8]) throws -> RelayMessage {
        let bundle = JsonBuilder().uint("v", 1).uint("suite", 2).string("ik", Base64s.encodeStd(v.ik.publicKey)).string("kem", Base64s.encodeStd(v.kem.publicKey.bytes)).raw("relay", JsonBuilder().string("url", v.relayURL).string("mailbox", v.mailbox).base64("pk", v.relayKey.publicKey).build()).bytes()
        let body = JsonBuilder().string("vault_id", v.vaultID).base64("vault_bundle", bundle).string("token", try v.token(for: d)).uint("state_seq", 2).base64("attestation", doc).bytes()
        let inner = Inner(id: Ulid.new(), type: "vault.enrolled", ts: Date(), body: body)
        return v.msg(try Envelope.sealSealed(d.kemKey, senderKid: Kid.anonymous, padded: try Inner.encode(inner, .sealed)).0)
    }

    /// A device whose enrollment built two requests (nonces 1 and 2).
    func twoRequests() async throws -> (VaultDevice, FakeVault) {
        let d = try await VaultDevice.create(base.config(InMemoryDeviceStateStore(), attestation: Self.check), secrets: try DeviceSecrets.generate())
        let v = try FakeVault(relayURL: base.relay.baseURL)
        var a = AltState()
        a.enrollNonce = [UInt8](repeating: 1, count: 32)
        a.enrollPcrs = Self.pcrs
        a.enrollNumber = 3
        a.enrollVaultID = v.vaultID
        a.enrollPrior = []
        let first = a.currentEnroll
        a.enrollNonce = [UInt8](repeating: 2, count: 32)
        a.enrollPrior = [try #require(first)]
        d.mem.withLock { d.setAlt(a) }
        return (d, v)
    }

    @Test func aLateVaultEnrolledForAnEarlierRequestIsAccepted() async throws {
        let (d, v) = try await twoRequests()
        try await d.handle(try enrolled(v, d, doc: [UInt8](repeating: 1, count: 32)))
        try await d.awaitEnrolled(timeout: 1)
        #expect(d.vaultID == v.vaultID && d.altState.releaseNumber == 3)
        #expect(d.altState.currentEnroll == nil && d.altState.enrollPrior.isEmpty)
    }

    @Test func aNonceOfNoRequestIsRefused() async throws {
        let (d, v) = try await twoRequests()
        try await d.handle(try enrolled(v, d, doc: [UInt8](repeating: 9, count: 32)))
        await #expect(throws: VaultStateError.self) { try await d.awaitEnrolled(timeout: 0.2) }
        #expect(d.vaultID == nil)
    }

    /// A vault.enrolled whose vault is not the one the request enrolled is not accepted, whatever its nonce.
    @Test func anotherVaultsEnrolledIsRefused() async throws {
        let (d, v) = try await twoRequests()
        var a = d.altState
        a.enrollVaultID = "another-vault"
        a.enrollPrior = []
        d.mem.withLock { d.setAlt(a) }
        try await d.handle(try enrolled(v, d, doc: [UInt8](repeating: 2, count: 32)))
        await #expect(throws: VaultStateError.self) { try await d.awaitEnrolled(timeout: 0.2) }
        #expect(d.vaultID == nil)
    }

    @Test func anAbandonedEnrollmentAcceptsNone() async throws {
        let (d, v) = try await twoRequests()
        try await d.abandonEnrollment()
        #expect(d.altState.enrollAttempts.isEmpty)
        try await d.handle(try enrolled(v, d, doc: [UInt8](repeating: 1, count: 32)))
        await #expect(throws: VaultStateError.self) { try await d.awaitEnrolled(timeout: 0.2) }
    }

    /// The earlier requests persist with the state, bounded.
    @Test func earlierRequestsAreKeptBounded() throws {
        var a = AltState()
        for i in 1...7 {
            var b = a
            if let cur = b.currentEnroll { b.enrollPrior = Array((b.enrollPrior + [cur]).suffix(AltState.maxPriorEnrolls)) }
            b.enrollNonce = [UInt8](repeating: UInt8(i), count: 32)
            b.enrollPcrs = Self.pcrs
            b.enrollVaultID = "v1"
            b.enrollAttestKeyID = [UInt8(i)]
            a = b
        }
        // IOS-PLAN §6.2: each kept request names the App Attest key it attested; the one vault.enrolled answers is kept.
        #expect(a.enrollAttempts.map(\.attestKeyID) == [[7], [6], [5], [4], [3]])
        let enrolled = a.applyingEnrolled(stateSeq: 1, attempt: a.enrollAttempts[2])
        #expect(enrolled.enrolledAttestKeyID == [5] && enrolled.enrollAttempts.isEmpty)
        #expect(try AltState.parse(StrictJson.parseObject(enrolled.marshal())) == enrolled)
        #expect(a.enrollPrior.count == AltState.maxPriorEnrolls && a.enrollAttempts.count == 5)
        let back = try AltState.parse(try StrictJson.parseObject(a.marshal()))
        #expect(back == a)
        #expect(try AltState.parse(StrictJson.parseObject(AltState().marshal())) == AltState())
    }
}

// swiftlint:enable line_length
