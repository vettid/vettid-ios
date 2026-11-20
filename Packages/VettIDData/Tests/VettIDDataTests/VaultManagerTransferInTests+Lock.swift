import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// A status read under way across a lock, on a paired device whose answer is a setup step of an open vault.
extension VaultManagerTransferInTests {
    /// "Finish the move" (`.setup(.finishing)`, from the vault's status): a read whose answer is that step, under way across a
    /// lock, gives Locked, as `vault.locking` itself turns a setup step.
    @Test func aFinishingStepReadAcrossALockIsLocked() async throws {
        defer { phone.close() }
        try await transferred()
        // Locked first (so the lock event itself changes no phase): only the read's answer, a setup step, could open it.
        service.status("locked")
        try await m.refresh()
        #expect(m.phase == .locked)
        service.status("unlocked") // another device opened it
        service.holdStatusReads()
        let reading = Task { try await m.refresh() }
        #expect(await eventually { service.heldStatusReads == 1 })
        let before = m.latestLockAt
        service.sendEvent("vault.locking", #"{"reason":"test"}"#)
        #expect(await eventually { m.latestLockAt != before })
        service.releaseStatusReads()
        try await reading.value
        #expect(m.phase == .locked, "\(m.phase)")
    }
}
