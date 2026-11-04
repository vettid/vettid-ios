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

    /// `token_used` to the (retried) deposit: it may have been delivered, so the `hs.resp` is waited for.
    @Test func tokenUsedOnTheDepositWaitsForTheResp() async throws {
        let (d, v) = try await enrolled()
        // The first attempt is answered 503 and retried; the retry is answered `token_used`.
        base.relay.refuseStatus = 503
        base.relay.refuseDeposits = "unavailable"
        base.relay.refuseOnly = 1
        base.relay.thenRefuse = (403, RelayError.tokenUsed)
        base.relay.recordRefused = true
        let outcome = enroll(d)
        let (_, initMsg) = try await base.relay.nextDeposit()
        try await settle(0.5)
        #expect(!outcome.finished, "waiting for the resp, not failed")
        try await d.handle(try v.respond(initMsg, d))
        try await settle(0.5)
        #expect(!outcome.finished, "the resp came: on to device.paired")
        #expect(d.hasVault)
    }

    /// No `hs.resp` by the token's `exp` plus 60 s (virtual time): it fails with the relay's answer, the handshake dropped.
    @Test func tokenUsedWithoutARespFailsAfterTheBound() async throws {
        let offset = Box<TimeInterval>(0)
        let (d, _) = try await enrolled(now: { Date().addingTimeInterval(offset.value) })
        base.relay.refuseStatus = 503
        base.relay.refuseDeposits = "unavailable"
        base.relay.refuseOnly = 1
        base.relay.thenRefuse = (403, RelayError.tokenRevoked)
        base.relay.recordRefused = true
        let outcome = enroll(d)
        _ = try await base.relay.nextDeposit()
        try await settle(0.3)
        #expect(!outcome.finished, "inside the bound")
        offset.value = 40 * 86_400 // past the standing token's exp plus 60 s
        for _ in 0..<200 where !outcome.finished { try await settle(0.05) }
        #expect((outcome.error as? RelayError)?.code == RelayError.tokenRevoked)
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

    private func codeFor(_ v: FakeVault, _ d: VaultDevice) throws -> (qr: InviteQr, inviteID: String) {
        // The transfer suite shares this suite's fake relay for the claim.
        let exp = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 600).rounded(.down))
        let inviteID = Ulid.new()
        let bundle = InviteBundle(kind: .app, inviteID: inviteID, remote: false, vault: v.principal, token: try v.token(for: d), exp: exp, capabilities: [Capabilities.recoveryR])
        let sealed = try InviteBundle.seal(try bundle.marshal())
        base.relay.putClaim("abcdefghijklmnopqrstuvwxyz", sealed.blob)
        return (InviteQr(kind: .app, relay: base.relay.baseURL, claimID: "abcdefghijklmnopqrstuvwxyz", hash: sealed.hash, key: sealed.key, exp: UInt64(exp.timeIntervalSince1970)), inviteID)
    }
}

// swiftlint:enable line_length
