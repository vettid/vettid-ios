import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// A lost answer to `pin.change` or `credential.password.change` (VAULT-MESSAGING §11.14.9 "A lost answer") at the
/// client: the request goes with the inner id and `exp` the app stored, no answer leaves the request to send again, the
/// resend is the same request (a cached answer the device already saw still completes it), `stale_credential` is never
/// retried with the typed secrets, and `credential.version` comes with the vault's `ts`, which moves the vault's clock.
@Suite struct LostAnswerTests {
    let ops = CredentialOpsTests()

    /// A monotonic clock the test moves.
    final class Uptime: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000

        var now: TimeInterval { lock.withLock { value } }
        func advance(_ s: TimeInterval) { lock.withLock { value += s } }
    }

    /// A device state store whose saves fail once armed, from its [after]th save on (a full disk, or protected data gone
    /// once the phone locks).
    final class FailingStore: DeviceStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var b: [UInt8]?
        private var left: Int?

        func arm(after n: Int) { lock.withLock { left = n } }
        func load() -> [UInt8]? { lock.withLock { b } }
        func clear() { lock.withLock { b = nil } }

        func save(_ state: [UInt8]) throws {
            try lock.withLock {
                if let n = left {
                    if n <= 0 { throw CocoaError(.fileWriteOutOfSpace) }
                    left = n - 1
                }
                b = state
            }
        }
    }

    func config(timeout: TimeInterval, uptime: Uptime = Uptime(), store: DeviceStateStore = InMemoryDeviceStateStore()) -> DeviceConfig {
        let relay = ops.base.relay
        return DeviceConfig(
            name: "phone", relayURL: relay.baseURL, transport: HTTPTransport(session: relay.server.session, sleep: { _ in }),
            store: store, enrolledAttestation: .skipForTests, requestTimeout: timeout, uptime: { uptime.now }
        )
    }

    /// A paired device holding blob 1, with a pool of UTKs.
    struct Holder {
        let d: VaultDevice
        let v: FakeVault
        let api: VaultApi
        let keys: [String: KemPrivateKey]
    }

    func holder(timeout: TimeInterval = 5, uptime: Uptime = Uptime(), store: DeviceStateStore = InMemoryDeviceStateStore()) async throws -> Holder {
        let (d, v) = try await ops.base.pairedDevice(cfg: config(timeout: timeout, uptime: uptime, store: store))
        let api = VaultApi(device: d) { true }
        let fetch = Task { try await api.credentialFetch() }
        try await ops.answer(v, d, "credential.get", #"{"credential":"AQID","version":1}"#)
        try await ops.answer(v, d, "credential.ack")
        try await fetch.value
        let (utks, keys) = try ops.pool(3)
        let top = Task { try await api.topUpUTKs() }
        try await ops.answer(v, d, "credential.utk.get", utks)
        try await top.value
        return Holder(d: d, v: v, api: api, keys: keys)
    }

    func open(_ v: FakeVault) async throws -> Inner { try v.open(try await ops.base.relay.nextDeposit().payload) }

    /// Delivers [inner] to the device in a new envelope (the vault re-sends a cached response so).
    func deliver(_ v: FakeVault, _ d: VaultDevice, _ inner: Inner) async throws {
        try await d.handle(v.msg(try #require(v.keyring.current()).seal(inner)))
    }

    /// The change goes with the stored id and `exp`, and the blob of the stored version; a version that moved meanwhile is
    /// refused before anything is sent.
    @Test func theChangeCarriesTheStoredIdAndExp() async throws {
        let h = try await holder()
        let (d, v, api) = (h.d, h.v, h.api)
        let change = try await api.newChange()
        #expect(change.version == 1)
        #expect(abs(change.exp.timeIntervalSince(d.vaultNow()) - ChangeRequest.validFor) < 1)
        let task = Task { try await api.pinChange(pin: "975310", newPin: "864201", password: "pw", newUnlockSecret: [UInt8](repeating: 1, count: 32), change: change) }
        let req = try await open(v)
        #expect(req.type == VaultApi.typePinChange && req.id == change.id)
        #expect(abs(try #require(req.exp).timeIntervalSince(change.exp)) < 0.001)
        try await deliver(v, d, Inner(id: Ulid.new(), type: req.type, ts: Date(), re: req.id, status: Inner.statusOK, body: Array(#"{"credential":"BAUG","version":2,"epoch_advanced":true}"#.utf8)))
        try await ops.answer(v, d, "credential.ack")
        #expect(try await task.value)
        let stale = ChangeRequest(id: d.newRequestID(), exp: Date().addingTimeInterval(600), version: 1)
        await #expect(throws: VaultStateError.self) {
            try await api.credentialChangePassword(password: "a", newPassword: "b", pin: "975310", change: stale)
        }
        #expect(await ops.base.relay.noDeposit(within: 0.2))
    }

    /// No answer to the automatic resends: ``ChangeUnanswered`` with the request. The resend is the same request (same
    /// id, `exp` and body); the vault's cached answer, which the device saw already after its wait ended, completes it.
    @Test func aResendIsTheSameRequestAndGetsTheCachedAnswer() async throws {
        let holder = try await holder(timeout: 0.3)
        let (d, v, api, keys) = (holder.d, holder.v, holder.api, holder.keys)
        let change = try await api.newChange()
        let task = Task { try await api.credentialChangePassword(password: "old pw", newPassword: "new pw", pin: "975310", change: change) }
        var sent: [Inner] = []
        for _ in 0...VaultDevice.appRetries { sent.append(try await open(v)) }
        #expect(Set(sent.map(\.id)) == [change.id] && Set(sent.map(\.body)).count == 1)
        var held: HeldRequest?
        do {
            try await task.value
            Issue.record("answered")
        } catch let u as ChangeUnanswered {
            held = u.held
        }
        let h = try #require(held)
        #expect(h.id == change.id && h.type == VaultApi.typePasswordChange && h.exp == change.exp)
        // The answer arrives late: no one waits for it any more.
        let cached = Inner(id: Ulid.new(), type: h.type, ts: Date(), re: h.id, status: Inner.statusOK, body: Array(#"{"credential":"BAUG","version":2}"#.utf8))
        try await deliver(v, d, cached)
        #expect(d.credentialVersion == 1)
        let again = Task { try await api.resendChange(h) }
        let resent = try await open(v)
        #expect(resent.id == h.id && resent.body == sent[0].body && resent.exp.map { abs($0.timeIntervalSince(h.exp)) < 0.001 } == true)
        #expect(try ops.payload(resent, v.vaultID, keys).string("new_password") == "new pw")
        try await deliver(v, d, cached)
        try await ops.answer(v, d, "credential.ack")
        _ = try await again.value
        #expect(d.credentialVersion == 2)
    }

    /// The device state cannot be saved after the request was deposited: the change may still apply, so it is
    /// ``ChangeUnanswered`` (decided), never a failure that would drop its marker.
    @Test func aSaveThatFailsAfterTheDepositIsNoAnswer() async throws {
        let store = FailingStore()
        let h = try await holder(store: store)
        let change = try await h.api.newChange()
        // The UTK taken and the outbox entry are saved; the save after the deposit fails.
        store.arm(after: 2)
        let task = Task { try await h.api.credentialChangePassword(password: "a", newPassword: "b", pin: "975310", change: change) }
        #expect(try await open(h.v).id == change.id, "deposited")
        do {
            try await task.value
            Issue.record("no error")
        } catch let u as ChangeUnanswered {
            #expect(u.held.id == change.id)
        }
    }

    /// The vault's clock runs on the monotonic clock that counts the phone's sleep.
    @Test func theDefaultClockCountsSleep() {
        let cfg = DeviceConfig(
            name: "phone", relayURL: "https://relay.example", transport: HTTPTransport(session: .shared, sleep: { _ in }),
            store: InMemoryDeviceStateStore(), enrolledAttestation: .skipForTests
        )
        let sleeping = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
        #expect(abs(cfg.uptime() - sleeping) < 1)
    }

    /// A resend that gets no answer is one deposit and one wait.
    @Test func aResendWithoutAnswerIsOneDeposit() async throws {
        let holder = try await holder(timeout: 0.2)
        let (v, api) = (holder.v, holder.api)
        let change = try await api.newChange()
        let task = Task { try await api.pinChange(pin: "975310", newPin: "864201", password: "pw", newUnlockSecret: [UInt8](repeating: 1, count: 32), change: change) }
        for _ in 0...VaultDevice.appRetries { _ = try await open(v) }
        let h = try #require(await unanswered(task))
        await #expect(throws: ChangeUnanswered.self) { _ = try await api.resendChange(h) }
        #expect(try await open(v).id == h.id)
        #expect(await ops.base.relay.noDeposit(within: 0.3), "one deposit")
    }

    func unanswered(_ t: Task<Bool, any Error>) async -> HeldRequest? {
        do {
            _ = try await t.value
        } catch let u as ChangeUnanswered {
            return u.held
        } catch {}
        return nil
    }

    /// `stale_credential` to either change is not sent again with the typed secrets: the latest blob is fetched and the
    /// refusal thrown.
    @Test func aStaleCredentialIsNotRetried() async throws {
        for type in [VaultApi.typePinChange, VaultApi.typePasswordChange] {
            let h = try await holder()
            let (d, v, api) = (h.d, h.v, h.api)
            let task = Task {
                if type == VaultApi.typePinChange {
                    _ = try await api.pinChange(pin: "975310", newPin: "864201", password: "pw", newUnlockSecret: [UInt8](repeating: 1, count: 32), change: try await api.newChange())
                } else {
                    try await api.credentialChangePassword(password: "a", newPassword: "b", pin: "975310", change: try await api.newChange())
                }
            }
            try await ops.answer(v, d, type, code: "stale_credential", errorBody: "{}")
            try await ops.answer(v, d, "credential.get", #"{"credential":"BAUG","version":2}"#)
            try await ops.answer(v, d, "credential.ack")
            await #expect(throws: VaultOpError.self) { try await task.value }
            #expect(d.credentialVersion == 2)
            #expect(await ops.base.relay.noDeposit(within: 0.3), "no second \(type)")
        }
    }

    /// `credential.version` comes with the answer's `ts`; the vault's clock is that `ts` plus the monotonic time since,
    /// and an older `ts` (a cached answer) does not move it back.
    @Test func theVaultsClockFollowsItsAnswers() async throws {
        let up = Uptime()
        let h = try await holder(uptime: up)
        let (d, v, api) = (h.d, h.v, h.api)
        let stamp = Date().addingTimeInterval(-3_600)
        let task = Task { try await api.credentialVersionStamped() }
        let req = try await open(v)
        try await deliver(v, d, Inner(id: Ulid.new(), type: req.type, ts: stamp, re: req.id, status: Inner.statusOK, body: Array(#"{"exists":true,"version":1}"#.utf8)))
        let info = try await task.value
        #expect(info.info.version == 1 && abs(info.ts.timeIntervalSince(stamp)) < 0.001)
        // The holder's own answers were stamped now: the clock never goes back to the older stamp.
        #expect(d.vaultNow() > stamp.addingTimeInterval(3_000))
        let later = d.vaultNow()
        up.advance(42)
        #expect(abs(d.vaultNow().timeIntervalSince(later) - 42) < 0.001)
    }
}

// swiftlint:enable line_length
