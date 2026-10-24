import Foundation
import Testing
@testable import VettIDVault
import VettIDAltChan
import VettIDAltChanTesting
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// A direct transfer, the new app's side (VAULT-MESSAGING §6.7.1, §11.14.10): the claim, the attested `hs.init` with the
/// app key and the unlock secret, the SAS, `device.paired` with the `user_guid`, a rejection, and abandoning. Mirrors
/// vettid-android `VaultDeviceTest`'s transfer cases.
/// An attester that remembers which keys were discarded (IOS-PLAN §6.2).
final class RecordingAttester: Attester, @unchecked Sendable {
    let inner = TestIOSAttester()
    private let lock = NSLock()
    private var gone: [[UInt8]] = []
    var discarded: [[UInt8]] { lock.withLock { gone } }

    func attest(_ challenge: [UInt8]) throws -> DeviceAttest { try inner.attest(challenge) }
    func assert(_ signed: AttestSigned) throws -> DeviceAssertion { try inner.assert(signed) }
    func discard(keyID: [UInt8]) throws { lock.withLock { gone.append(keyID) } }
}

@Suite struct TransferDeviceTests {
    let base = VaultDeviceTests()

    /// A transfer code for [v]: the sealed bundle on the fake relay's claim, and the QR that names it.
    func code(_ v: FakeVault, _ d: VaultDevice, kind: InviteKind = .app, seconds: TimeInterval = 600, capabilities: [String]? = [Capabilities.recoveryR]) throws -> (qr: InviteQr, inviteID: String) {
        let exp = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + seconds).rounded(.down))
        let inviteID = Ulid.new()
        let bundle = InviteBundle(kind: kind, inviteID: inviteID, remote: false, vault: v.principal, token: try v.token(for: d), exp: exp, capabilities: kind == .app ? capabilities : nil)
        let sealed = try InviteBundle.seal(try bundle.marshal())
        let claimID = "abcdefghijklmnopqrstuvwxyz"
        base.relay.putClaim(claimID, sealed.blob)
        return (InviteQr(kind: kind, relay: base.relay.baseURL, claimID: claimID, hash: sealed.hash, key: sealed.key, exp: UInt64(exp.timeIntervalSince1970)), inviteID)
    }

    struct NewPhone {
        let device: VaultDevice
        let vault: FakeVault
        let attester: TestIOSAttester
        let secrets: DeviceSecrets
    }

    func newDevice() async throws -> NewPhone {
        let secrets = DeviceSecrets(identity: Ed25519PrivateKey.generate(), kem: try KemPrivateKey.generate(), relay: Ed25519PrivateKey.generate(), apiKey: [UInt8](repeating: 0x30, count: 91))
        let d = try await VaultDevice.create(base.config(InMemoryDeviceStateStore()), secrets: secrets)
        return NewPhone(device: d, vault: try FakeVault(relayURL: base.relay.baseURL), attester: TestIOSAttester(), secrets: secrets)
    }

    @Test func theAttestedHsInitCarriesTheAppKeyAndTheUnlockSecretAndThePairedEventCompletesIt() async throws {
        let p = try await newDevice()
        let (d, v, attester, secrets) = (p.device, p.vault, p.attester, p.secrets)
        let (qr, inviteID) = try code(v, d)
        let seen = Box<(caps: [String], scale: UInt64)?>(nil)
        let secret = [UInt8](repeating: 7, count: 32)
        try await d.startTransfer(link: try qr.link(), attester: attester) { caps, scale in
            seen.value = (caps, scale)
            return secret
        }
        #expect(seen.value?.caps == ["recovery_r"] && seen.value?.scale == 1)
        let (mbx, initMsg) = try await base.relay.nextDeposit()
        #expect(mbx == v.mailbox)
        let (resp, body) = try v.respondOpening(initMsg, d, ctx: inviteID)
        // §6.2: a transfer's hs.init carries the attestation, the app key and (release R) the unlock secret.
        #expect(body.deviceAttest?.platform == "ios" && body.apiKey == secrets.apiKey && body.unlockSecret == secret)
        #expect(body.sasCommit != nil)
        let key = try #require(body.deviceAttest?.iosKeyID)
        #expect(d.altState.transferAttestKeyID == key && d.pairingSas == nil && !d.paired)
        let sas = Task { try await d.awaitPairingSas() }
        try await d.handle(resp)
        try v.fin(try await base.relay.nextDeposit().payload, d)
        #expect(try await sas.value == d.pairingSas && d.pairingSas != nil)
        let waiting = Task { try await d.awaitTransfer(timeout: 5) }
        try await d.handle(try v.seal("device.paired", #"{"device_id":"dev-2","role":"app","vault_id":"\#(v.vaultID)","transfer":true,"user_guid":"guid-1234","credential_version":4}"#))
        #expect(try await waiting.value == "guid-1234")
        #expect(d.deviceID == "dev-2" && d.vaultID == v.vaultID && d.paired)
        // The attested key is the one the vault bound now.
        #expect(d.altState.transferAttestKeyID == nil && d.altState.enrolledAttestKeyID == key)
    }

    @Test func aCodeOfAnotherKindOrAnExpiredOneSendsNothing() async throws {
        let p = try await newDevice()
        let (d, v, attester) = (p.device, p.vault, p.attester)
        let other = try code(v, d, kind: .desktop, capabilities: nil)
        await #expect(throws: NotATransferCode(expired: false)) { try await d.startTransfer(link: try other.qr.link(), attester: attester) { _, _ in nil } }
        let q = InviteQr(kind: .app, relay: base.relay.baseURL, claimID: "abcdefghijklmnopqrstuvwxyz", hash: [UInt8](repeating: 1, count: 32), key: [UInt8](repeating: 2, count: 32), exp: UInt64(Date().timeIntervalSince1970) - 5)
        await #expect(throws: NotATransferCode(expired: true)) { try await d.startTransfer(link: try q.link(), attester: attester) { _, _ in nil } }
        await #expect(throws: NotATransferCode(expired: false)) { try await d.startTransfer(link: "not a link", attester: attester) { _, _ in nil } }
        #expect(await base.relay.noDeposit(within: 0.2) && !d.hasVault)
    }

    /// A bundle this build does not accept (the callback throws) sends nothing and pins no vault.
    @Test func aRefusedBundleSendsNothingAndPinsNoVault() async throws {
        let p = try await newDevice()
        let (d, v, attester) = (p.device, p.vault, p.attester)
        let (qr, _) = try code(v, d)
        struct Refused: Error {}
        await #expect(throws: Refused.self) { try await d.startTransfer(link: try qr.link(), attester: attester) { _, _ in throw Refused() } }
        #expect(await base.relay.noDeposit(within: 0.2) && !d.hasVault && d.altState.transferAttestKeyID == nil)
    }

    /// Without release R's secret (a bundle without capabilities) the earlier `hs.init` is sent: no secret.
    @Test func withoutASecretTheHsInitHasNone() async throws {
        let p = try await newDevice()
        let (d, v, attester) = (p.device, p.vault, p.attester)
        let (qr, inviteID) = try code(v, d, capabilities: nil)
        try await d.startTransfer(link: try qr.link(), attester: attester) { caps, _ in
            #expect(caps.isEmpty)
            return nil
        }
        let (_, body) = try v.respondOpening(try await base.relay.nextDeposit().payload, d, ctx: inviteID)
        #expect(body.unlockSecret == nil && body.apiKey != nil)
    }

    /// The wait for the SAS ends with the task: a cancelled wait throws, and a late `hs.resp` changes nothing for it.
    @Test func theWaitForTheSasHonoursCancellation() async throws {
        let d = try await newDevice().device
        let wait = Task { try await d.awaitPairingSas() }
        try await Task.sleep(nanoseconds: 50_000_000)
        wait.cancel()
        await #expect(throws: CancellationError.self) { _ = try await wait.value }
    }

    /// The `device.paired` of a transfer is applied when it is handled, before it is acked: the event in memory is lost with the
    /// process, the state is not (VAULT-MESSAGING §11.14.10 rule 5: a paired transfer completes at any later start).
    @Test func aPairedTransferIsAppliedWhenItIsHandled() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = DeviceSecrets(identity: Ed25519PrivateKey.generate(), kem: try KemPrivateKey.generate(), relay: Ed25519PrivateKey.generate(), apiKey: [UInt8](repeating: 0x30, count: 91))
        let d = try await VaultDevice.create(base.config(store), secrets: secrets)
        let v = try FakeVault(relayURL: base.relay.baseURL)
        let (qr, inviteID) = try code(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let key = try #require(d.altState.transferAttestKeyID)
        try await d.handle(try v.respond(try await base.relay.nextDeposit().payload, d, ctx: inviteID))
        try v.fin(try await base.relay.nextDeposit().payload, d)
        // Nothing awaits it.
        try await d.handle(try v.seal("device.paired", #"{"device_id":"dev-2","role":"app","vault_id":"\#(v.vaultID)","transfer":true,"user_guid":"guid-1234"}"#))
        #expect(d.deviceID == "dev-2" && d.transferUserGuid == "guid-1234" && d.altState.enrolledAttestKeyID == key)
        #expect(d.altState.transferAttestKeyID == nil && d.paired)
        // A device restored from the store (the next start) is paired all the same, and cannot be abandoned.
        let again = try #require(try VaultDevice.load(base.config(store), secrets: secrets))
        #expect(again.deviceID == "dev-2" && again.transferUserGuid == "guid-1234")
        #expect(try await again.abandonTransfer() == false && again.hasVault)
    }

    /// One collect, `wait=0` (VAULT-MESSAGING §11.14.10 rule 5): the `device.paired` that waits in the mailbox is applied; the
    /// message is acked.
    @Test func oneCollectAppliesAPairedTransferThatWaits() async throws {
        let p = try await newDevice()
        let (d, v, attester) = (p.device, p.vault, p.attester)
        let (qr, inviteID) = try code(v, d)
        try await d.startTransfer(link: try qr.link(), attester: attester) { _, _ in nil }
        try await d.handle(try v.respond(try await base.relay.nextDeposit().payload, d, ctx: inviteID))
        try v.fin(try await base.relay.nextDeposit().payload, d)
        let paired = try v.seal("device.paired", #"{"device_id":"dev-2","role":"app","vault_id":"\#(v.vaultID)","transfer":true,"user_guid":"guid-1234"}"#)
        base.relay.queue(paired)
        base.relay.serveMailbox = true
        try await d.collectOnce(timeout: 5)
        #expect(try await d.awaitTransfer(timeout: 1) == "guid-1234")
        #expect(d.deviceID == "dev-2" && d.transferUserGuid == "guid-1234")
        #expect(await base.relay.waitAcked(paired.msgID))
        try await d.transferCompleted()
        #expect(d.transferUserGuid == nil)
    }

    /// A collect that fails (the relay refuses, or cannot be reached) throws: the caller drops at once.
    @Test func aFailedCollectThrows() async throws {
        let p = try await newDevice()
        base.relay.refuseCollect = "mailbox_unknown"
        base.relay.serveMailbox = true
        await #expect(throws: (any Error).self) { try await p.device.collectOnce(timeout: 5) }
    }

    @Test func aRejectionEndsTheWait() async throws {
        let p = try await newDevice()
        let (d, v, attester) = (p.device, p.vault, p.attester)
        let (qr, inviteID) = try code(v, d)
        try await d.startTransfer(link: try qr.link(), attester: attester) { _, _ in nil }
        try await d.handle(try v.respond(try await base.relay.nextDeposit().payload, d, ctx: inviteID))
        try v.fin(try await base.relay.nextDeposit().payload, d)
        let waiting = Task { try await d.awaitTransfer(timeout: 5) }
        try await d.handle(try v.seal("device.pair.rejected", "{}"))
        await #expect(throws: PairingRejected.self) { _ = try await waiting.value }
        #expect(!d.paired && d.deviceID == nil)
    }

    @Test func abandoningDropsTheHandshakeTheVaultAndTheAttestedKey() async throws {
        let p = try await newDevice()
        let (d, v, attester) = (p.device, p.vault, p.attester)
        let (qr, _) = try code(v, d)
        try await d.startTransfer(link: try qr.link(), attester: attester) { _, _ in nil }
        _ = try await base.relay.nextDeposit()
        #expect(d.hasVault && d.altState.transferAttestKeyID != nil)
        try await d.abandonTransfer()
        #expect(!d.hasVault && d.altState.transferAttestKeyID == nil && d.pairingSas == nil)
        // A paired device is not abandoned.
        let (paired, _) = try await base.pairedDevice()
        try await paired.abandonTransfer()
        #expect(paired.hasVault && paired.deviceID != nil)
    }

    /// A `hs.init` that could not be sent: the key it attested is bound by no vault, and the handshake and the pinned vault
    /// go with it.
    @Test func aFailedDepositDiscardsTheAttestedKey() async throws {
        let p = try await newDevice()
        let (d, v) = (p.device, p.vault)
        let attester = RecordingAttester()
        let (qr, _) = try code(v, d)
        base.relay.refuseDeposits = "token_revoked"
        await #expect(throws: (any Error).self) { try await d.startTransfer(link: try qr.link(), attester: attester) { _, _ in nil } }
        #expect(attester.discarded.count == 1 && !d.hasVault && d.altState.transferAttestKeyID == nil && d.pairingSas == nil)
    }

    /// A second code scanned while a transfer is open: the key the first attested can no longer be bound.
    @Test func aSecondCodeDiscardsTheFirstOnesKey() async throws {
        let p = try await newDevice()
        let (d, v) = (p.device, p.vault)
        let attester = RecordingAttester()
        let (first, _) = try code(v, d)
        try await d.startTransfer(link: try first.link(), attester: attester) { _, _ in nil }
        let firstKey = try #require(d.altState.transferAttestKeyID)
        let (second, _) = try code(v, d)
        try await d.startTransfer(link: try second.link(), attester: attester) { _, _ in nil }
        #expect(attester.discarded == [firstKey])
        #expect(d.altState.transferAttestKeyID != nil)
    }

    @Test func aPairedDeviceDoesNotStartATransfer() async throws {
        let (p, v) = try await base.pairedDevice()
        let (qr, _) = try code(v, p)
        await #expect(throws: VaultStateError.self) { try await p.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil } }
    }
}

// swiftlint:enable line_length
