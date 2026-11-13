import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay
import VettIDTesting

/// The lock gate before a request's sends (ANDROID-PLAN "While pending": nothing is sent to the vault but the lock and a
/// pending `call.end`): a re-send of the same id, and the one send of ``VaultDevice/requestOnce(_:body:timeout:exp:)``,
/// ask it; the lock and a lock-time call (``VaultDevice/lockTimeSend``) always go.
extension VaultDeviceTests {
    /// A re-send the gate holds is not sent: the request goes on waiting for the copy already out, and its answer still
    /// settles it.
    @Test func aRequestsResendIsHeldByTheLockGate() async throws {
        let (d, v) = try await pairedDevice(cfg: config(InMemoryDeviceStateStore(), timeout: 0.2))
        let open = Box(true)
        d.setFlushGate { open.value }
        let status = Task { try await d.op("vault.status") }
        let first = try v.open(try await relay.nextDeposit().payload)
        open.value = false
        #expect(await relay.noDeposit(within: 0.3), "no re-send while a lock is pending")
        try await d.handle(try v.seal("vault.status", #"{"vault_id":"x"}"#, re: first.id, status: Inner.statusOK))
        #expect(VaultJSON.string(VaultJSON.object(try await status.value), "vault_id") == "x")
    }

    /// With the gate open, the same id is re-sent as before.
    @Test func aRequestsResendGoesWhileTheGateAdmitsIt() async throws {
        let (d, v) = try await pairedDevice(cfg: config(InMemoryDeviceStateStore(), timeout: 0.2))
        d.setFlushGate { true }
        let status = Task { try await d.op("vault.status") }
        let first = try v.open(try await relay.nextDeposit().payload)
        let again = try v.open(try await relay.nextDeposit().payload)
        #expect(again.id == first.id)
        try await d.handle(try v.seal("vault.status", "{}", re: first.id, status: Inner.statusOK))
        _ = try await status.value
    }

    /// A single send the gate holds sends nothing and throws ``OutboxHeld`` (the app's `lock_pending`); the lock itself goes.
    @Test func aSingleSendIsHeldButTheLockGoes() async throws {
        let (d, v) = try await pairedDevice(cfg: config(InMemoryDeviceStateStore(), timeout: 0.2))
        d.setFlushGate { false }
        await #expect(throws: OutboxHeld.self) { _ = try await d.opOnce("call.start") }
        #expect(await relay.noDeposit(within: 0.2))
        let lock = Task { try await d.opOnce("vault.lock") }
        let req = try v.open(try await relay.nextDeposit().payload)
        #expect(req.type == "vault.lock")
        try await d.handle(try v.seal("vault.lock", "{}", re: req.id, status: Inner.statusOK))
        _ = try await lock.value
    }

    /// A lock-time call ("Lock it now"'s `vault.status`) is re-sent while the gate is shut.
    @Test func aLockTimeCallIsResentWhileTheGateIsShut() async throws {
        let (d, v) = try await pairedDevice(cfg: config(InMemoryDeviceStateStore(), timeout: 0.2))
        d.setFlushGate { false }
        let status = Task { try await VaultDevice.$lockTimeSend.withValue(true) { try await d.op("vault.status") } }
        let first = try v.open(try await relay.nextDeposit().payload)
        let again = try v.open(try await relay.nextDeposit().payload)
        #expect(again.id == first.id)
        try await d.handle(try v.seal("vault.status", "{}", re: first.id, status: Inner.statusOK))
        _ = try await status.value
    }

    /// "Lock it now"'s read of the opening (``VaultApi/statusUnlockID()``) is a lock-time call: re-sent while the gate is shut.
    @Test func lockItNowsStatusReadIsALockTimeCall() async throws {
        let (d, v) = try await pairedDevice(cfg: config(InMemoryDeviceStateStore(), timeout: 0.2))
        d.setFlushGate { false }
        let read = Task { try await VaultApi(device: d).statusUnlockID() }
        let first = try v.open(try await relay.nextDeposit().payload)
        let again = try v.open(try await relay.nextDeposit().payload)
        #expect(first.type == "vault.status" && again.id == first.id)
        let body = #"{"vault_id":"x","state":"unlocked","unlock_id":"u2"}"#
        try await d.handle(try v.seal("vault.status", body, re: first.id, status: Inner.statusOK))
        #expect(try await read.value == "u2")
    }

    /// A kept change's re-send the gate holds is not deposited: the change waits for the copy already out.
    @Test func aKeptChangesResendIsHeldByTheLockGate() async throws {
        let (d, v) = try await pairedDevice(cfg: config(InMemoryDeviceStateStore(), timeout: 0.2))
        let open = Box(true)
        d.setFlushGate { open.value }
        let held = HeldRequest(type: "pin.change", id: Ulid.new(), exp: Date().addingTimeInterval(600), body: VaultJSON.empty)
        let change = Task { try await d.requestKept(held, sends: 3) }
        let first = try v.open(try await relay.nextDeposit().payload)
        #expect(first.id == held.id)
        open.value = false
        #expect(await relay.noDeposit(within: 0.3), "no re-send while a lock is pending")
        try await d.handle(try v.seal("pin.change", "{}", re: held.id, status: Inner.statusOK))
        _ = try await change.value
    }

    /// A `call.start` the gate holds left nothing: no hang-up is queued for it.
    @Test func aHeldCallStartQueuesNoHangUp() async throws {
        let (d, _) = try await pairedDevice(cfg: config(InMemoryDeviceStateStore(), timeout: 0.2))
        d.setFlushGate { false }
        await #expect(throws: OutboxHeld.self) {
            _ = try await VaultApi(device: d).callStart("conn-1", pinnedFingerprint: "fp", sdp: Self.callSdp)
        }
        #expect(outboxTypes(d).isEmpty, "no call.end")
        #expect(await relay.noDeposit(within: 0.2))
    }

    /// A single send the gate holds: the call's answer, ringing and ICE send nothing while a lock is pending.
    @Test(arguments: ["call.answer", "call.ringing", "call.ice"])
    func aCallsSingleSendIsHeld(type: String) async throws {
        let (d, _) = try await pairedDevice()
        d.setFlushGate { false }
        await #expect(throws: OutboxHeld.self) { _ = try await d.sendOnce(type) }
        #expect(await relay.noDeposit(within: 0.2))
    }

    /// A blob upload the gate holds uploads nothing.
    @Test func aBlobUploadIsHeld() async throws {
        let (d, _) = try await pairedDevice()
        d.setFlushGate { false }
        await #expect(throws: OutboxHeld.self) { _ = try await d.uploadBlobToVault([1, 2, 3]) }
        #expect(relay.blobs.isEmpty)
    }

    /// A renewal of the standing token the gate holds mints nothing: the token's recorded expiry stays as it was.
    @Test func aHeldRenewalMintsNothing() async throws {
        let (d, _) = try await pairedDevice()
        let issued = d.mem.withLock { d.st.issuedExpMs }
        d.setFlushGate { false }
        await #expect(throws: OutboxHeld.self) { try await d.renewStandingToken() }
        #expect(d.mem.withLock { d.st.issuedExpMs } == issued)
        #expect(await relay.noDeposit(within: 0.2))
    }

    /// A first send the gate holds is not counted (no "send without an answer" for the owner check's estimate).
    @Test func aHeldFirstSendIsNotCounted() async throws {
        let (d, _) = try await pairedDevice()
        d.setFlushGate { false }
        let counted = Box(0)
        let watch = Task { for await _ in d.countedEnds() { counted.value += 1 } }
        defer { watch.cancel() }
        await #expect(throws: OutboxHeld.self) { _ = try await d.op("vault.owner-check") }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(counted.value == 0)
    }

    /// The collection a lock-time call starts does not inherit the mark: its handlings ask the gate as any.
    @Test func aCollectionStartedByALockTimeCallIsNotOne() async throws {
        let (d, v) = try await pairedDevice()
        let marked = Box<Bool?>(nil)
        d.beforeFinalSave = { marked.value = VaultDevice.lockTimeSend }
        relay.serveMailbox = true
        relay.queue(try v.seal("message.new", #"{"connection_id":"c1","message_id":"m1","direction":"in","text":"hi","sent_at":"x"}"#))
        VaultDevice.$lockTimeSend.withValue(true) { d.start() }
        defer { d.stop() }
        for _ in 0..<300 where marked.value == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(marked.value == false)
    }
}
