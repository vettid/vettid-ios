import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// A call that holds the vault's collection in the background does not postpone the app lock (IOS-PLAN §6.4): its timeout counts
/// from leaving the foreground, on the clock that cannot be set back, and applies on the return as if the app had been away all
/// along, however long the call went on.
extension AppLockTests {
    final class CallHold {
        var live = true
    }

    @Test func aCallHoldingTheCollectionDoesNotPostponeTheAppLock() async throws {
        let service = try FakeVaultService()
        let phone = try TestVaultPhone(service: service)
        defer { phone.close() }
        let m = phone.manager
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: "402817") { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: "402817") { _ in }
        try await m.finishSetup()

        let l = try await enabled()
        try l.setTimeout(.oneMinute)
        // The scene leaves the foreground: the app lock marks the time, and the vault's side holds the collection for a call.
        l.onBackground()
        let call = CallHold()
        m.holdCollection { call.live }
        await m.onBackground(budget: .seconds(1))
        #expect(m.session != nil, "the call keeps the collection")
        // The call goes on past the timeout, and ends in the background: the collection stops, and the lock still counts from the start.
        clock.up += 61
        call.live = false
        m.collectionHoldEnded()
        #expect(m.session == nil)
        l.onForeground()
        #expect(l.state == .locked, "the time the call held the app in the background counts")
    }
}
