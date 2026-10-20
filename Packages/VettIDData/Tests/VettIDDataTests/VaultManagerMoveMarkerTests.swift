import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// The way back to release N after leaving or a restart (IOS-PLAN §4.3) end to end against ``FakeVaultService``: the
/// `move_unconfirmed` marker written at `update: moved`, `failed` set by a failure of release N+1 (never by a wrong PIN),
/// kept across a restart, "Return to release N" from the unlock screen only with `failed` and only on the member's tap,
/// and each clearing (an opening on N+1, `abandoned`, `wrong_release`, `410`, `vault.release`).
@MainActor
@Suite(.serialized) struct VaultManagerMoveMarkerTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"

    init() throws {
        service = try FakeVaultService()
        service.stampsOnVaultClock = true
        phone = try TestVaultPhone(service: service, requestTimeout: TestVaultPhone.shortRequestTimeout)
    }

    var m: VaultManager { phone.manager }

    /// Open on release 3, release 4 published, then the approval's unlock alone: `moved`, and nothing after it (as a
    /// process killed right after `moved`).
    func moved() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        service.listsRelease4 = true
        await m.releaseUpdate.refreshOffer()
        let offer = try #require(m.releaseUpdate.offer)
        try await m.lockForUpdate()
        let taken = TakenPin(pin: pin, generation: m.phoneSecrets.pinGeneration)
        let r = await m.updateUnlock(pin: taken, approve: offer.target, abandon: false) {}
        #expect(r == .moved)
        let u = try #require(m.unconfirmedMove)
        #expect(u.from.number == 3 && u.from.pcr0 == FakeVaultService.pcr0 && u.to.number == 4 && !u.failed)
    }

    /// The app killed and started again: the unlock screen, with the marker read from the device's records.
    func restart() async throws {
        try phone.restart()
        try await m.refresh()
        #expect(m.phase == .locked)
    }

    /// Moved, then the process killed before the second unlock: the marker without `failed` (no offer); the next unlock
    /// reaches release 4, which confirms the move and clears it.
    @Test func aRestartRightAfterMovedUnlocksAsUsual() async throws {
        defer { phone.close() }
        try await moved()
        try await restart()
        #expect(m.unconfirmedMove?.failed == false)
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(m.unconfirmedMove == nil && m.session?.device.altState.releaseNumber == 4)
        #expect(service.pendingMove == nil)
    }

    /// A wrong PIN on release 4 neither sets `failed` nor clears the marker.
    @Test func aWrongPinKeepsTheMarkerAsItIs() async throws {
        defer { phone.close() }
        try await moved()
        guard case .badPin = try await m.unlock(pin: "999999") else {
            Issue.record("not a wrong PIN")
            return
        }
        #expect(m.unconfirmedMove?.failed == false)
    }

    /// Release 4 fails (an enclave error), then a restart: the marker has `failed`; "Return to release 3" goes only on
    /// the member's tap, abandons (`update: abandoned`), records release 3 and clears the marker.
    @Test func aFailedNewReleaseOffersTheWayBackAfterARestart() async throws {
        defer { phone.close() }
        try await moved()
        service.unlockAnswers(.sealed("retry"))
        _ = try await m.unlock(pin: pin)
        #expect(m.unconfirmedMove?.failed == true)
        try await restart()
        #expect(m.unconfirmedMove?.failed == true)
        let updatesBefore = service.releaseUpdates.count
        #expect(service.releaseUpdates.count == updatesBefore, "nothing sent to release 3 before the tap")
        #expect(m.returnToPreviousRelease(pin: pin))
        #expect(m.releaseUpdate.progress?.step == .abandoning)
        await m.releaseUpdate.settle()
        #expect(m.releaseUpdate.progress?.step == .abandoned)
        let back = try #require(service.releaseUpdates.last)
        #expect(back.to == FakeVaultService.pcr0 && back.toRelease == 3)
        #expect(m.unconfirmedMove == nil && m.session?.device.altState.releaseNumber == 3)
        #expect(m.phase == .unlocked)
    }

    /// Without `failed` the unlock screen's way back does not start.
    @Test func theWayBackNeedsFailed() async throws {
        defer { phone.close() }
        try await moved()
        let updatesBefore = service.releaseUpdates.count
        #expect(!m.returnToPreviousRelease(pin: pin))
        #expect(m.releaseUpdate.progress == nil && service.releaseUpdates.count == updatesBefore)
    }

    /// Release 3 refuses the way back with `wrong_release`: the move was confirmed; the marker goes, with its text.
    @Test func wrongReleaseClearsIt() async throws {
        defer { phone.close() }
        try await moved()
        service.unlockAnswers(.sealed("retry"), .sealed("wrong_release"))
        _ = try await m.unlock(pin: pin)
        #expect(m.returnToPreviousRelease(pin: pin))
        await m.releaseUpdate.settle()
        let p = try #require(m.releaseUpdate.progress)
        #expect(p.step == .returnEnded && p.failureCode == VaultManager.codeReturnConfirmed)
        #expect(m.unconfirmedMove == nil)
    }

    /// Release 3 can no longer be reached for it (`410 release_unavailable`): the marker goes, with its text.
    @Test func releaseUnavailableClearsIt() async throws {
        defer { phone.close() }
        try await moved()
        service.unlockAnswers(.sealed("retry"))
        _ = try await m.unlock(pin: pin)
        service.askedReleaseUnavailable = true
        #expect(m.returnToPreviousRelease(pin: pin))
        await m.releaseUpdate.settle()
        let p = try #require(m.releaseUpdate.progress)
        #expect(p.step == .returnEnded && p.failureCode == VaultManager.codeReturnUnavailable)
        #expect(m.unconfirmedMove == nil)
    }

    /// The vault's `sync.event{kind: "vault.release"}` naming release 4 confirms the move.
    @Test func theVaultReleaseSyncEventClearsIt() async throws {
        defer { phone.close() }
        try await moved()
        service.unlockAnswers(.sealed("retry"))
        _ = try await m.unlock(pin: pin)
        #expect(m.unconfirmedMove?.failed == true)
        service.sendReleaseSync(4)
        #expect(await eventually { m.unconfirmedMove == nil })
    }

    /// (§4.3 point 6) Routed to release 3 for two fetches, then 4: the PIN goes only to release 4.
    @Test func aRouteNamingTheOldReleaseIsWaitedFor() async throws {
        defer { phone.close() }
        try await moved()
        try await restart()
        service.lagRoutesAfterMove = 2
        let unlocks = service.unlocks.count
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(service.unlocks.count == unlocks + 1, "one unlock, to release 4")
        #expect(m.session?.device.altState.releaseNumber == 4 && m.unconfirmedMove == nil)
    }

    /// Routed to release 3 for every fetch: the neutral failure, `failed` set, and never a PIN to release 3; the check
    /// before the PIN is no rollback and offers nothing meanwhile.
    @Test func aRouteThatKeepsNamingTheOldReleaseFailsNeutrally() async throws {
        defer { phone.close() }
        try await moved()
        try await restart()
        service.lagRoutesAfterMove = 100
        let p = try await m.preflight()
        #expect(p.routed.number == 3 && !p.rollback && p.offer == nil)
        let unlocks = service.unlocks.count
        let r = try await m.unlock(pin: pin)
        #expect(r == .failed(.vaultUnavailable, code: VaultManager.codeReleaseNotRouted))
        #expect(service.unlocks.count == unlocks, "no PIN sent to release 3")
        #expect(m.unconfirmedMove?.failed == true)
    }

    /// A release the manifest does not know served for the way back ends it only when release N itself is no longer in
    /// the trusted manifest; reading the manifest (the offer after an unlock) ends it too once N is gone.
    @Test func onlyReleaseNGoneFromTheManifestEndsIt() async throws {
        defer { phone.close() }
        try await moved()
        service.unlockAnswers(.sealed("retry"))
        _ = try await m.unlock(pin: pin)
        #expect(await m.returnEnded(.failed(.releaseUnknown, code: "enclave")) == nil)
        #expect(m.unconfirmedMove?.failed == true, "N still listed: kept")
        service.delistsRelease3 = true
        await m.releaseUpdate.refreshOffer()
        #expect(m.unconfirmedMove == nil)
    }

    /// Only N+1's own failures set `failed`: never this phone's attestation, keys, records, a cancellation or a dropped
    /// session.
    @Test func onlyTheNewReleasesOwnFailuresCount() {
        let yes: [UnlockAttempt] = [
            .failed(.releaseEnded, code: "release_unavailable"), .failed(.enclave, code: "enclave"),
            .failed(.noResponse, code: nil), .failed(.vaultUnavailable, code: "release_starting"),
            .failed(.vaultUnavailable, code: VaultManager.codeReleaseNotRouted), .failed(.retry, code: "retry"),
            .failed(.other, code: "release_key"), .failed(.other, code: "vault_missing"),
        ]
        let no: [UnlockAttempt] = [
            .badPin(retryAfterSeconds: 0), .backoff(retryAfterSeconds: 5), .failed(.network, code: nil),
            .failed(.phoneLocked, code: "phone_locked"), .failed(.retry, code: "app_attest_pending_full"),
            .failed(.other, code: "app_attest"), .failed(.other, code: "crypto"), .failed(.other, code: "malformed"),
            .failed(.other, code: "session_dropped"), .failed(.other, code: nil), .failed(.attestation, code: "attestation"),
            .failed(.changeChecking, code: "change_held"), .failed(.vaultUnavailable, code: VaultManager.codeVaultDeleting),
        ]
        for a in yes { #expect(VaultManager.failsNewRelease(a), "\(a)") }
        for a in no { #expect(!VaultManager.failsNewRelease(a), "\(a)") }
    }
}
