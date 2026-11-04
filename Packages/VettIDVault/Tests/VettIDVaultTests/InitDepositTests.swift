import Foundation
import Testing
@testable import VettIDVault
import VettIDAltChan
import VettIDAltChanTesting
import VettIDCrypto
import VettIDRelay

// swiftlint:disable line_length

/// The `hs.init` is deposited outside the device lock (VAULT-MESSAGING §8.6, 0.83.0): a deposit that fails after the vault's
/// `hs.resp` was handled does not destroy the handshake; `token_used` and `token_revoked` on it wait for the `hs.resp` until
/// the token's `exp` plus 60 s; a refused transfer leaves nothing pinned, also after a kill.
@Suite struct InitDepositTests {
    let base = VaultDeviceTests()

    /// A device with a vault that sent `vault.enrolled`, its store and its secrets.
    func enrolled(now: @escaping @Sendable () -> Date = { Date() }) async throws -> (VaultDevice, FakeVault) {
        let store = InMemoryDeviceStateStore()
        let d = try await VaultDevice.create(base.config(store, now: now), secrets: try DeviceSecrets.generate())
        let v = try FakeVault(relayURL: base.relay.baseURL)
        try await d.handle(try v.enrolled(d))
        try await d.awaitEnrolled(timeout: 1)
        return (d, v)
    }

    /// Runs `completeEnrollment` and reports whether it has ended, and how.
    final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var failure: (any Error)?
        private var done = false
        var finished: Bool { lock.withLock { done } }
        var error: (any Error)? { lock.withLock { failure } }
        func end(_ e: (any Error)?) { lock.withLock { done = true; failure = e } }
    }

    func enroll(_ d: VaultDevice, timeout: TimeInterval = 20) -> Outcome {
        let o = Outcome()
        Task {
            do {
                try await d.completeEnrollment(timeout: timeout)
                o.end(nil)
            } catch {
                o.end(error)
            }
        }
        return o
    }

    func settle(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }

    /// The `hs.resp` came back before the deposit's failure was known: the pairing survives, and the wait goes on.
    @Test func aDepositThatFailsAfterTheRespWasHandledKeepsTheHandshake() async throws {
        let (d, v) = try await enrolled()
        base.relay.refuseStatus = 503
        base.relay.refuseDeposits = "unavailable"
        base.relay.refuseOnly = 3
        base.relay.recordRefused = true
        let outcome = enroll(d)
        let (_, initMsg) = try await base.relay.nextDeposit()
        try await d.handle(try v.respond(initMsg, d))
        try await settle(2.5) // the relay client's attempts end in the failure
        #expect(!outcome.finished, "still waiting for device.paired, not failed")
        #expect(d.hasVault)
    }

    func newPhone(now: @escaping @Sendable () -> Date = { Date() }) async throws -> (VaultDevice, FakeVault) {
        let secrets = DeviceSecrets(identity: Ed25519PrivateKey.generate(), kem: try KemPrivateKey.generate(), relay: Ed25519PrivateKey.generate(), apiKey: [UInt8](repeating: 0x30, count: 91))
        let d = try await VaultDevice.create(base.config(InMemoryDeviceStateStore(), now: now), secrets: secrets)
        return (d, try FakeVault(relayURL: base.relay.baseURL))
    }

    func transfer(_ d: VaultDevice, _ qr: InviteQr) -> Outcome {
        let o = Outcome()
        Task {
            do {
                try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
                o.end(nil)
            } catch {
                o.end(error)
            }
        }
        return o
    }

    /// The first attempt is answered 503 and retried; the retry is answered with [code], the message stored all the same.
    func retryRefused(_ code: String) {
        base.relay.refuseStatus = 503
        base.relay.refuseDeposits = "unavailable"
        base.relay.refuseOnly = 1
        base.relay.thenRefuse = (403, code)
        base.relay.recordRefused = true
    }

    /// `token_used` to the retried deposit of an open token (a transfer link's): it may have been delivered, so the `hs.resp`
    /// is waited for.
    @Test func tokenUsedOnTheOpenTokenWaitsForTheResp() async throws {
        let (d, v) = try await newPhone()
        let (qr, inviteID) = try codeFor(v, d)
        retryRefused(RelayError.tokenUsed)
        let outcome = transfer(d, qr)
        let (_, initMsg) = try await base.relay.nextDeposit()
        try await settle(0.5)
        #expect(!outcome.finished, "waiting for the resp, not failed")
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        for _ in 0..<100 where !outcome.finished { try await settle(0.05) }
        #expect(outcome.finished && outcome.error == nil, "the resp came: the transfer goes on")
        #expect(d.hasVault)
    }

    /// No `hs.resp` by the open token's `exp` plus 60 s (virtual time): it fails with the relay's answer, the handshake and the
    /// pinned vault dropped.
    @Test func tokenRevokedOnTheOpenTokenWithoutARespFailsAfterTheBound() async throws {
        let offset = Box<TimeInterval>(0)
        let (d, v) = try await newPhone(now: { Date().addingTimeInterval(offset.value) })
        let (qr, _) = try codeFor(v, d)
        retryRefused(RelayError.tokenRevoked)
        let outcome = transfer(d, qr)
        _ = try await base.relay.nextDeposit()
        try await settle(0.3)
        #expect(!outcome.finished, "inside the bound")
        offset.value = 400 // past the open token's exp (5 minutes) plus 60 s
        for _ in 0..<200 where !outcome.finished { try await settle(0.05) }
        #expect((outcome.error as? RelayError)?.code == RelayError.tokenRevoked)
        #expect(!d.hasVault)
    }

    /// A standing token (enrollment, recovery) is not waited on: the rule is for the open token alone.
    @Test func tokenUsedOnAStandingTokenFailsAtOnce() async throws {
        let (d, _) = try await enrolled()
        retryRefused(RelayError.tokenUsed)
        let outcome = enroll(d)
        for _ in 0..<100 where !outcome.finished { try await settle(0.05) }
        #expect((outcome.error as? RelayError)?.code == RelayError.tokenUsed)
    }

    /// A store whose writes fail once armed.
    final class FlakyStore: DeviceStateStore, @unchecked Sendable {
        private let inner = InMemoryDeviceStateStore()
        private let lock = NSLock()
        private var failing = false
        func fail() { lock.withLock { failing = true } }
        func load() throws -> [UInt8]? { try inner.load() }
        func save(_ state: [UInt8]) throws {
            if lock.withLock({ failing }) { throw URLError(.cannotWriteToFile) }
            try inner.save(state)
        }
        func clear() throws { try inner.clear() }
    }

    /// An `hs.resp` that lands between the failure of the deposit and the drop of the handshake leaves the pairing alone.
    @Test func anAnswerLandingBeforeTheCleanupKeepsTheHandshake() async throws {
        let (d, _) = try await enrolled()
        let hookRan = Box<Bool>(false)
        d.initRaceHook = { [d] i in
            hookRan.value = true
            d.mem.withLock { d.answeredInit = ObjectIdentifier(i); d.ini = nil }
        }
        base.relay.refuseStatus = 503
        base.relay.refuseDeposits = "unavailable"
        base.relay.refuseOnly = 3
        let outcome = enroll(d)
        try await settle(2.5)
        #expect(hookRan.value, "the answer landed between the failure and the cleanup")
        #expect(!outcome.finished, "on to device.paired, not failed")
    }

    /// The record of an answered handshake does not outlive it: a new one starts with none.
    @Test func aNewHandshakeStartsWithNoAnsweredRecord() async throws {
        let (d, _) = try await enrolled()
        d.mem.withLock { d.answeredInit = ObjectIdentifier(d) }
        let outcome = enroll(d)
        _ = try await base.relay.nextDeposit()
        #expect(d.mem.withLock { d.answeredInit } == nil)
        _ = outcome
    }

    /// An outbox entry whose save failed is neither kept in the outbox nor marked in flight.
    @Test func aFailedSaveLeavesNoEntryAndNoMark() async throws {
        let store = FlakyStore()
        let d = try await VaultDevice.create(base.config(store), secrets: try DeviceSecrets.generate())
        let v = try FakeVault(relayURL: base.relay.baseURL)
        try await d.handle(try v.enrolled(d))
        try await d.awaitEnrolled(timeout: 1)
        let completing = Task { try await d.completeEnrollment(timeout: 5) }
        let (_, initMsg) = try await base.relay.nextDeposit()
        try await d.handle(try v.respond(initMsg, d))
        completing.cancel()
        store.fail()
        let marksBefore = d.mem.withLock { d.outboxInFlight }
        await #expect(throws: (any Error).self) {
            _ = try await d.lock.withLock {
                try d.enqueueLocked(id: nil, type: "relay.token.refresh", body: VaultJSON.empty, re: nil, status: nil, exp: nil)
            }
        }
        let (kept, marks) = d.mem.withLock { (d.st.outbox.filter { $0.type == "relay.token.refresh" }.count, d.outboxInFlight) }
        #expect(kept == 0 && marks == marksBefore, "no entry of that kind, and no mark left behind")
    }

    /// The wait for the resp ends when the handshake is gone (dropped, rejected, replaced).
    @Test func theWaitEndsWhenTheHandshakeIsGone() async throws {
        let (d, v) = try await newPhone()
        let (qr, _) = try codeFor(v, d)
        retryRefused(RelayError.tokenUsed)
        let outcome = transfer(d, qr)
        _ = try await base.relay.nextDeposit()
        try await settle(0.3)
        #expect(!outcome.finished)
        d.mem.withLock { d.ini = nil }
        for _ in 0..<100 where !outcome.finished { try await settle(0.05) }
        #expect((outcome.error as? RelayError)?.code == RelayError.tokenUsed, "it stopped waiting at once")
    }

    /// A transfer whose `hs.init` could not be saved leaves nothing pinned or attested.
    @Test func aTransferWhoseStateCouldNotBeSavedLeavesNothing() async throws {
        let store = FlakyStore()
        let secrets = DeviceSecrets(identity: Ed25519PrivateKey.generate(), kem: try KemPrivateKey.generate(), relay: Ed25519PrivateKey.generate(), apiKey: [UInt8](repeating: 0x30, count: 91))
        let d = try await VaultDevice.create(base.config(store), secrets: secrets)
        let v = try FakeVault(relayURL: base.relay.baseURL)
        let (qr, _) = try codeFor(v, d)
        let attester = RecordingAttester()
        store.fail()
        await #expect(throws: (any Error).self) { try await d.startTransfer(link: try qr.link(), attester: attester) { _, _ in nil } }
        #expect(!d.hasVault && d.altState.transferAttestKeyID == nil && attester.discarded.count == 1)
    }

    /// An attester that fails after the vault is pinned leaves neither the vault nor an attest key id behind.
    @Test func aFailingAttesterLeavesNothingPinned() async throws {
        struct Broken: Error {}
        final class Failing: Attester, @unchecked Sendable {
            func attest(_ challenge: [UInt8]) throws -> DeviceAttest { throw Broken() }
            func assert(_ signed: AttestSigned) throws -> DeviceAssertion { throw Broken() }
            func discard(keyID: [UInt8]) throws {}
        }
        let (d, v) = try await newPhone()
        let (qr, _) = try codeFor(v, d)
        await #expect(throws: Broken.self) { try await d.startTransfer(link: try qr.link(), attester: Failing()) { _, _ in nil } }
        #expect(!d.hasVault && d.altState.transferAttestKeyID == nil)
    }

    /// A second transfer that fails before its handshake is built, while the first one's is in flight, cleans up too.
    @Test func aSecondTransferThatFailsToPrepareLeavesNothing() async throws {
        let (d, v) = try await newPhone()
        let (first, _) = try codeFor(v, d, claimID: "abcdefghijklmnopqrstuvwxyz")
        let attester = RecordingAttester()
        try await d.startTransfer(link: try first.link(), attester: attester) { _, _ in nil }
        #expect(d.hasVault)
        let (second, _) = try codeFor(v, d, claimID: "bcdefghijklmnopqrstuvwxyza")
        d.quiet() // the next handshake is refused before it is built
        await #expect(throws: (any Error).self) { try await d.startTransfer(link: try second.link(), attester: attester) { _, _ in nil } }
        #expect(!d.hasVault && d.altState.transferAttestKeyID == nil)
    }

    /// `token_used` to a first attempt (no retry before it) is not a lost answer: the handshake fails at once.
    @Test func tokenUsedOnAFirstAttemptFailsAtOnce() async throws {
        let (d, _) = try await enrolled()
        base.relay.refuseStatus = 403
        base.relay.refuseDeposits = RelayError.tokenUsed
        let outcome = enroll(d)
        for _ in 0..<100 where !outcome.finished { try await settle(0.05) }
        #expect((outcome.error as? RelayError)?.code == RelayError.tokenUsed)
    }

    /// A transfer whose `hs.init` the relay refused leaves nothing behind in the store: no vault pinned without a device id,
    /// no attest key id, and the attested key is discarded.
    @Test func aRefusedTransferLeavesNothingAfterAKill() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = DeviceSecrets(identity: Ed25519PrivateKey.generate(), kem: try KemPrivateKey.generate(), relay: Ed25519PrivateKey.generate(), apiKey: [UInt8](repeating: 0x30, count: 91))
        let d = try await VaultDevice.create(base.config(store), secrets: secrets)
        let v = try FakeVault(relayURL: base.relay.baseURL)
        let (qr, _) = try codeFor(v, d)
        let attester = RecordingAttester()
        base.relay.refuseStatus = 403
        base.relay.refuseDeposits = "token_invalid"
        await #expect(throws: RelayError.self) { try await d.startTransfer(link: try qr.link(), attester: attester) { _, _ in nil } }
        #expect(attester.discarded.count == 1)
        let again = try #require(try VaultDevice.load(base.config(store), secrets: secrets))
        #expect(!again.hasVault && again.altState.transferAttestKeyID == nil)
    }

    private func codeFor(_ v: FakeVault, _ d: VaultDevice, claimID: String = "abcdefghijklmnopqrstuvwxyz") throws -> (qr: InviteQr, inviteID: String) {
        // The transfer suite shares this suite's fake relay for the claim.
        let exp = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 600).rounded(.down))
        let inviteID = Ulid.new()
        let open = try DepositTokens.mintOpen(v.relayKey, audience: base.relay.baseURL, now: Date())
        let bundle = InviteBundle(kind: .app, inviteID: inviteID, remote: false, vault: v.principal, token: open, exp: exp, capabilities: [Capabilities.recoveryR])
        let sealed = try InviteBundle.seal(try bundle.marshal())
        base.relay.putClaim(claimID, sealed.blob)
        return (InviteQr(kind: .app, relay: base.relay.baseURL, claimID: claimID, hash: sealed.hash, key: sealed.key, exp: UInt64(exp.timeIntervalSince1970)), inviteID)
    }
}

// swiftlint:enable line_length
