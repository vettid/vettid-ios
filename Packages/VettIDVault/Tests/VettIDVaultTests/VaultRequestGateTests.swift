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
}
