import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// (§6.7.1) Without the vault's `user_guid` the unlock refuses (`no_user_guid`), so the update does not lock the vault
/// first: it fails as the unlock would have, with the vault still open and nothing sent. The usual order otherwise
/// (``lockThenApproveThenMovedThenReopenWithTheSamePin()``).
extension ReleaseUpdateManagerTests {
    func refusedWithoutUserGuid(_ m: ReleaseUpdateManager) throws {
        let p = try #require(m.progress)
        #expect(p.step == .failed && p.failure == .notSupported && p.failureCode == UnlockAttempt.codeNoUserGuid)
        #expect(p.vaultOpen, "not locked")
    }

    @Test func withoutAUserGuidTheUpdateLocksNothing() async throws {
        let ops = Ops()
        ops.guidUsable = false
        let m = manager(ops)
        #expect(m.start(pin: "246802", offer: offer))
        await m.settle()
        #expect(ops.log.isEmpty && ops.unlocks.isEmpty, "\(ops.log)")
        try refusedWithoutUserGuid(m)
    }

    /// "Try again" after a failure that left the vault open locks it again first: not without a `user_guid` either.
    @Test func tryAgainWithoutAUserGuidLocksNothing() async throws {
        let ops = Ops()
        ops.lockFails = VaultFailure(.network)
        let m = manager(ops)
        #expect(m.start(pin: "246802", offer: offer))
        await m.settle()
        #expect(ops.log == ["lock"] && m.progress?.step == .failed && m.progress?.vaultOpen == true)
        ops.lockFails = nil
        ops.guidUsable = false
        m.retry(pin: "246802", generation: nil)
        await m.settle()
        #expect(ops.log == ["lock"] && ops.unlocks.isEmpty, "\(ops.log)")
        try refusedWithoutUserGuid(m)
    }
}
