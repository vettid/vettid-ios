import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay
import VettIDTesting

/// A request's first send held by the lock gate (ANDROID-PLAN "While pending"; as vettid-android #363): nothing is sent,
/// `lock_pending` (``OutboxHeld``), no request left unsettled, and the UTK it took back in the pool. A change or a renew so
/// held is not "unanswered" (the manager clears its marker); a change's re-send so held stays undecided.
extension LostAnswerTests {
    private func unsettled(_ d: VaultDevice) -> [String: Int64] { d.mem.withLock { d.st.unsettled ?? [:] } }

    @Test func aHeldFirstRequestSendsNothing() async throws {
        let h = try await holder()
        h.d.setFlushGate { false }
        await #expect(throws: OutboxHeld.self) { _ = try await h.d.op("vault.status") }
        #expect(await ops.base.relay.noDeposit(within: 0.2))
    }

    /// A credential operation held at its send: its UTK back, nothing unsettled.
    @Test func aHeldCredentialOperationGivesItsUtkBack() async throws {
        let h = try await holder()
        #expect(h.d.knowsVaultTime, "its exp is fixed with nothing sent: held at the request itself")
        let utks = h.d.utkCount
        h.d.setFlushGate { false }
        await #expect(throws: OutboxHeld.self) {
            _ = try await h.api.criticalUseApprove("r7", password: "pw", payloadSha256: Bytes.sha256(Array("x".utf8)))
        }
        #expect(await ops.base.relay.noDeposit(within: 0.2))
        #expect(h.d.utkCount == utks)
        #expect(unsettled(h.d).isEmpty)
    }

    /// A PIN change whose lock goes pending once it is fixed: held at its send, its UTK back, nothing unsettled, and thrown
    /// as held (not unanswered), so the manager clears its marker.
    @Test func aHeldChangeGivesItsUtkBackAndIsNotUnanswered() async throws {
        let h = try await holder()
        let utks = h.d.utkCount
        let open = Box(true)
        h.d.setFlushGate { open.value }
        let marked = Marked()
        let task = Task {
            try await h.api.pinChange(pin: "975310", newPin: "864201", password: "pw") { change in
                marked.set(change)
                open.value = false // the lock goes pending
                return [UInt8](repeating: 1, count: 32)
            }
        }
        try await ops.answer(h.v, h.d, "credential.version", #"{"exists":true,"version":1}"#)
        await #expect(throws: OutboxHeld.self) { _ = try await task.value }
        #expect(marked.change != nil)
        #expect(await ops.base.relay.noDeposit(within: 0.2))
        #expect(h.d.utkCount == utks)
        #expect(unsettled(h.d).isEmpty)
    }

    /// A renew so held: the same.
    @Test func aHeldRenewGivesItsUtkBack() async throws {
        let h = try await holder()
        let utks = h.d.utkCount
        let open = Box(true)
        h.d.setFlushGate { open.value }
        let task = Task {
            try await h.api.secretRenew(pin: "975310", password: "pw", onMarker: { _ in
                open.value = false
                return [UInt8](repeating: 1, count: 32)
            }, onAnswered: {})
        }
        try await ops.answer(h.v, h.d, "credential.version", #"{"exists":true,"version":1}"#)
        await #expect(throws: OutboxHeld.self) { try await task.value }
        #expect(await ops.base.relay.noDeposit(within: 0.2))
        #expect(h.d.utkCount == utks)
        #expect(unsettled(h.d).isEmpty)
    }

    /// A change's re-send held at its send: nothing goes, and it stays undecided (``ChangeUnanswered``): it went out before.
    @Test func aHeldChangeResendStaysUndecided() async throws {
        let h = try await holder()
        let held = HeldRequest(type: VaultApi.typePinChange, id: Ulid.new(), exp: Date().addingTimeInterval(600), body: VaultJSON.empty)
        h.d.setFlushGate { false }
        await #expect(throws: ChangeUnanswered.self) { _ = try await h.api.resendChange(held) }
        #expect(await ops.base.relay.noDeposit(within: 0.2))
    }

    /// A credential operation in a process that has not heard the vault yet: held at the `credential.version` that fixes its
    /// `exp`, its UTK back, nothing unsettled.
    @Test func aCredentialOperationHeldWhileItsExpIsFixedGivesItsUtkBack() async throws {
        let store = InMemoryDeviceStateStore()
        let h = try await holder(store: store)
        h.d.stop()
        let d = try #require(try VaultDevice.load(config(timeout: 5, store: store), secrets: h.d.secrets))
        #expect(!d.knowsVaultTime)
        let utks = d.utkCount
        d.setFlushGate { false }
        await #expect(throws: OutboxHeld.self) {
            let api = VaultApi(device: d) { true }
            _ = try await api.criticalUseApprove("r7", password: "pw", payloadSha256: Bytes.sha256(Array("x".utf8)))
        }
        #expect(await ops.base.relay.noDeposit(within: 0.2))
        #expect(d.utkCount == utks)
        #expect(unsettled(d).isEmpty)
    }

    /// A reset held at its send, as a change: its UTK back, nothing unsettled, thrown as held.
    @Test func aHeldResetGivesItsUtkBack() async throws {
        let h = try await holder()
        let utks = h.d.utkCount
        let open = Box(true)
        h.d.setFlushGate { open.value }
        let task = Task {
            try await h.api.credentialReset(pin: "975310", password: "pw", newPassword: "a new password") { _ in open.value = false }
        }
        try await ops.answer(h.v, h.d, "credential.version", #"{"exists":true,"version":1,"key":"k1"}"#)
        await #expect(throws: OutboxHeld.self) { try await task.value }
        #expect(await ops.base.relay.noDeposit(within: 0.2))
        #expect(h.d.utkCount == utks)
        #expect(unsettled(h.d).isEmpty)
    }
}
