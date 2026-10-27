import Foundation
import Testing
import VettIDAltChan
@testable import VettIDData
import VettIDDataTesting

/// A vault being deleted (IOS-PLAN §4.2) end to end against ``FakeVaultService``: the vault's
/// `device.unlinked{vault_deleted}` closes the open vault at once and stores the marker; the member API's status is read
/// on the schedule (held here by ``TestVaultPhone/deletionPauses``), at a start, at a return to the foreground and on
/// Check again; `{vault: null}`, a `401` or a `403` never ends it nor erases (owner decision, 2026-10-24); the member's confirmed
/// removal does, with the one-time notice. The member API's status alone never opens this state.
@MainActor
@Suite(.serialized) struct VaultManagerDeletingTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
        // The opening's list reads done (the items are read last in their chain, the attachments probed beside them), so
        // that none of them is on its way at the event: the test checks that nothing new is sent after it.
        #expect(await eventually { m.items.load == .loaded && m.attachments.available })
    }

    /// The files left in the phone's data directory.
    var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: phone.directory.path)) ?? [] }

    /// The vault says it is being deleted; the member API still lists it.
    func deleting() async throws {
        try await setUp()
        service.unlinkThisPhone(reason: VaultManager.reasonVaultDeleted)
        #expect(await eventually { m.phase == .deleting })
    }

    /// Nothing erased: still being deleted, the marker and the files stay, no notice.
    func expectKept() throws {
        #expect(m.phase == .deleting && m.deletion != nil && m.record.value.deleting != nil && !m.vaultDeletedNotice)
        #expect(!files.isEmpty)
        #expect(try phone.wipeTargets.keysLeft())
    }

    func expectGone() throws {
        #expect(m.phase == .signedOut && m.deletion == nil && m.vaultDeletedNotice)
        #expect(files.isEmpty, "files left: \(files)")
        #expect(try !phone.wipeTargets.keysLeft())
    }

    /// The event while the vault is open: closed at once (no session, no lists), the marker stored with a 10-minute
    /// bound, and nothing more sent: an unlock is refused before anything goes out.
    @Test func theEventClosesTheOpenVaultAtOnce() async throws {
        defer { phone.close() }
        try await deleting()
        #expect(m.session == nil && m.connections.connections.isEmpty)
        let marker = try #require(m.record.value.deleting)
        #expect(marker.vaultID == m.record.value.vaultID)
        #expect(marker.until.timeIntervalSince(marker.since) == VaultManager.deletingBound)
        let d = try #require(m.deletion)
        #expect(!d.slow && d.until == marker.until)
        let seen = service.requestsSeen.count
        let unlocks = service.unlocks.count
        let r = try await m.unlock(pin: pin)
        #expect(r == .failed(.vaultUnavailable, code: VaultManager.codeVaultDeleting))
        #expect(service.unlocks.count == unlocks)
        #expect(service.requestsSeen.count == seen, "sent after the event: \(service.requestsSeen.dropFirst(seen))")
        #expect(m.phase == .deleting)
    }

    /// The status still listing the vault as unlocked, then locked: still being deleted. `{vault: null}` is advisory
    /// (owner decision, 2026-10-24): it never ends this state and never erases.
    @Test func noVaultNeverErases() async throws {
        defer { phone.close() }
        try await deleting()
        service.status("unlocked")
        #expect(await m.checkDeletionAgain() == .listed && m.phase == .deleting)
        service.status("locked")
        #expect(await m.checkDeletionAgain() == .listed && m.phase == .deleting)
        service.status("locked", noVault: true)
        #expect(await m.checkDeletionAgain() == .unconfirmed)
        try expectKept()
    }

    /// A `401` to the app key (the same bare answer for a deleted vault and for a clock, nonce, signature or key fault)
    /// and a `403` conclude nothing: the data stays.
    @Test func unauthorizedAndForbiddenNeverErase() async throws {
        defer { phone.close() }
        try await deleting()
        service.statusUnauthorized = true
        #expect(await m.checkDeletionAgain() == .unconfirmed)
        try expectKept()
        service.statusUnauthorized = false
        service.statusForbidden = true
        #expect(await m.checkDeletionAgain() == .unconfirmed)
        try expectKept()
    }

    /// The reads' mapping: no answer or failure is `gone`; a `401` for the clock keeps its hint; 5xx, 429 and the rest are
    /// unreachable; a paused service concludes nothing.
    @Test func noReadSaysGone() {
        func fail(_ status: Int, _ code: String) -> DeletionRead { .of(failure: MemberApiError(status: status, code: code)) }
        #expect(fail(401, MemberApiError.unauthorized) == .unconfirmed)
        #expect(fail(401, MemberApiError.clockSkew) == .unconfirmedClock)
        #expect(fail(403, "forbidden") == .unconfirmed)
        #expect(fail(503, MemberApiError.vaultUnavailable) == .unreachable)
        #expect(fail(500, "internal") == .unreachable)
        #expect(fail(429, MemberApiError.rateLimited) == .unreachable)
        #expect(DeletionRead.of(failure: URLError(.timedOut)) == .unreachable)
        #expect(DeletionRead.of(vaultListed: false, servicePaused: false) == .unconfirmed)
        #expect(DeletionRead.of(vaultListed: true, servicePaused: false) == .listed)
        #expect(DeletionRead.of(vaultListed: false, servicePaused: true) == .unreachable)
        #expect(DeletionRead.of(vaultListed: true, servicePaused: true) == .unreachable)
    }

    /// Past the bound the member's confirmed removal erases (the existing erase of this phone), with the notice.
    @Test func aConfirmedRemovalPastTheBoundErases() async throws {
        defer { phone.close() }
        try await deleting()
        // The schedule's task checks the bound before its first sleep: the clock moves only once it sleeps, else it ends
        // as "still finishing" without ever sleeping.
        #expect(await eventually { phone.deletionPauses.lengths.count == 1 })
        phone.clockAhead = VaultManager.deletingBound + 1
        service.statusUnauthorized = true
        phone.deletionPauses.release()
        #expect(await eventually { m.deletion?.slow == true })
        #expect(await m.checkDeletionAgain() == .unconfirmed && m.phase == .deleting)
        try await m.eraseThisPhone()
        try expectGone()
    }

    /// A clock moved back is past the bound (within a minute of tolerance), and its wait is never as long as the move.
    @Test func aClockMovedBackDoesNotShortenOrStretchTheBound() {
        let since = Date(timeIntervalSince1970: 1_000_000), until = since.addingTimeInterval(600)
        #expect(!VaultDeletion.pastBound(since: since, until: until, now: since.addingTimeInterval(300)))
        #expect(VaultDeletion.pastBound(since: since, until: until, now: until))
        #expect(!VaultDeletion.pastBound(since: since, until: until, now: since.addingTimeInterval(-59)))
        #expect(VaultDeletion.pastBound(since: since, until: until, now: since.addingTimeInterval(-61)))
        #expect(VaultDeletion.pastBound(since: since, until: until, now: since.addingTimeInterval(-86400)))
    }

    /// A start with the clock a day behind the marker is "still finishing" at once, with no long wait.
    @Test func aClockBehindTheMarkerIsStillFinishingAtOnce() async throws {
        defer { phone.close() }
        try await deleting()
        #expect(await eventually { !phone.deletionPauses.lengths.isEmpty }, "the first manager's schedule slept")
        let before = phone.deletionPauses.lengths
        phone.clockAhead = -86400
        try await phone.restart()
        try await m.refresh()
        #expect(await eventually { m.deletion?.slow == true })
        let waits = phone.deletionPauses.lengths
        #expect(!waits.isEmpty && waits.allSatisfy { $0 <= 60 })
        #expect(waits == before, "no new timer: still finishing at once")
    }

    /// The schedule's first read comes after its first pause (5 s); still listed, the state stays.
    @Test func theScheduleReads() async throws {
        defer { phone.close() }
        try await deleting()
        #expect(await eventually { phone.deletionPauses.lengths == [5] })
        service.status("locked", noVault: true)
        phone.deletionPauses.release()
        #expect(await eventually { phone.deletionPauses.lengths.count == 2 })
        #expect(m.phase == .deleting && m.deletion != nil, "the read found nothing definite")
        try expectKept()
    }

    /// At the bound with the vault still listed: "still finishing"; nothing then reads on its own, Check again does,
    /// and a return to the foreground finds the vault gone later.
    @Test func stillFinishingAfterTheBound() async throws {
        defer { phone.close() }
        try await deleting()
        #expect(await eventually { phone.deletionPauses.lengths.count == 1 })
        phone.clockAhead = VaultManager.deletingBound + 1
        phone.deletionPauses.release()
        #expect(await eventually { m.deletion?.slow == true })
        #expect(phone.deletionPauses.lengths.count == 1, "no timer after the bound")
        #expect(await m.checkDeletionAgain() == .listed && m.phase == .deleting)
        service.status("locked", noVault: true)
        m.onForeground()
        #expect(await eventually { m.phase == .deleting })
        #expect(await m.checkDeletionAgain() == .unconfirmed)
        try expectKept()
    }

    /// A process killed while the vault is being deleted starts again in "being deleted", never on the unlock screen,
    /// reads at once, and ends when the vault is gone.
    @Test func aRestartReopensBeingDeleted() async throws {
        defer { phone.close() }
        try await deleting()
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .deleting && m.session == nil)
        #expect(m.deletion?.slow == false)
        // Past the bound: "still finishing" at the start.
        phone.clockAhead = VaultManager.deletingBound + 1
        try await phone.restart()
        try await m.refresh()
        #expect(await eventually { m.deletion?.slow == true })
        service.status("locked", noVault: true)
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .deleting)
        #expect(await m.checkDeletionAgain() == .unconfirmed, "the start's read has ended")
        try expectKept()
        try await m.eraseThisPhone()
        try expectGone()
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .signedOut && !m.vaultDeletedNotice, "the notice is shown once")
    }

    /// The event while a release update shows its outcome: the update's screens close with the vault.
    @Test func theEventClosesAReleaseUpdate() async throws {
        defer { phone.close() }
        try await setUp()
        service.listsRelease4 = true
        await m.releaseUpdate.refreshOffer()
        let offer = try #require(m.releaseUpdate.offer)
        _ = m.releaseUpdate.start(pin: "111111", offer: offer)
        await m.releaseUpdate.settle()
        #expect(m.releaseUpdate.progress?.step == .badPin)
        service.unlinkThisPhone(reason: VaultManager.reasonVaultDeleted)
        #expect(await eventually { m.phase == .deleting })
        #expect(m.releaseUpdate.progress == nil)
    }

    /// The member API's `state` is a free string: a value this build does not know (`deleting`, a future one) opens the
    /// unlock screen as locked, never an error and never "being deleted" (only the vault's own event opens that).
    @Test func anUnknownStatusStateIsLocked() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.lock()
        for state in ["deleting", "some_future_state"] {
            service.status(state)
            try await m.refresh()
            #expect(m.phase == .locked && m.deletion == nil && m.record.value.deleting == nil, "state \(state)")
        }
    }

    /// The event during this phone's own deletion, whose request then failed: the deletion applied all the same, so
    /// "being deleted" opens (the event is not lost with the request).
    @Test func theEventDuringAFailedOwnDeletionIsNotLost() async throws {
        defer { phone.close() }
        try await setUp()
        m.ownDelete = OwnDelete()
        m.onVaultDeletedEvent()
        #expect(m.phase == .unlocked, "left to the deletion on its way")
        #expect(m.ownDeleteUnlinked())
        #expect(m.phase == .deleting && m.record.value.deleting != nil)
    }

    /// An unlock waiting for the route when "being deleted" begins posts nothing more.
    @Test func anUnlockInItsRouteWaitPostsNothingOnceDeleting() async throws {
        defer { phone.close() }
        try await setUp()
        service.listsRelease4 = true
        await m.releaseUpdate.refreshOffer()
        let offer = try #require(m.releaseUpdate.offer)
        try await m.lockForUpdate()
        let taken = TakenPin(pin: pin, generation: m.phoneSecrets.pinGeneration)
        #expect(await m.updateUnlock(pin: taken, approve: offer.target, abandon: false) {} == .moved)
        service.lagRoutesAfterMove = 1000
        let unlocks = service.unlocks.count
        let unlock = Task { try await m.unlock(pin: pin) }
        #expect(await eventually { service.lagRoutesAfterMove < 1000 }, "waiting for the route")
        m.enterDeleting(expOnPhone: nil)
        service.lagRoutesAfterMove = 0
        let r = try await unlock.value
        #expect(r == .failed(.vaultUnavailable, code: VaultManager.codeVaultDeleting))
        #expect(service.unlocks.count == unlocks, "nothing posted")
        #expect(m.phase == .deleting)
    }

    /// A wipe of this phone while the vault is being deleted removes the marker with the record; the notice shows once.
    @Test func aWipeRemovesTheMarker() async throws {
        defer { phone.close() }
        try await deleting()
        try await m.eraseThisPhone()
        #expect(m.record.value.deleting == nil && m.deletion == nil && m.phase == .signedOut)
        #expect(files.isEmpty && m.vaultDeletedNotice)
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .signedOut && m.deletion == nil && !m.vaultDeletedNotice)
    }
}
