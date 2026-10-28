import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// The wipe of this phone end to end (owner decision, 2026-10-05; vettid-android `LocalWipe`, `WipeRun`): an
/// authenticated proof of replacement (a sealed `unknown_device`, `device.unlinked{transferred|replaced}`) or the
/// member's confirmed erase leaves a fresh install; a failure never does (nothing is erased on an unreadable answer, a
/// lock, or a refusal of the relay); a wipe that cannot finish says so, and "Try again", the next start, or "Erase
/// VettID's data" finishes it.
@MainActor
@Suite(.serialized) struct VaultManagerWipeTests {
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
    }

    func lockedVault() async throws {
        try await setUp()
        try await m.lock()
        #expect(m.phase == .locked)
    }

    /// The files left in the phone's data directory.
    var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: phone.directory.path)) ?? [] }

    /// As freshly installed: no file, no key, signed out, nothing to lock.
    func expectFresh() throws {
        #expect(m.phase == .signedOut)
        #expect(files.isEmpty, "files left: \(files)")
        #expect(try !phone.wipeTargets.keysLeft())
        #expect(m.account == nil && !m.lockPending && m.ownerChecks.ownerCheck == nil)
    }

    /// A sealed `unknown_device` (§11.4) proves that another phone replaced this one: it is wiped at once (vettid-android
    /// `HolderPolicy`), and a new setup can start on it.
    @Test func aSealedUnknownDeviceWipesThePhone() async throws {
        defer { phone.close() }
        try await lockedVault()
        #expect(!files.isEmpty)
        service.unlockAnswers(.sealed("unknown_device"))
        #expect(try await m.unlock(pin: pin) == .failed(.other, code: "unknown_device"))
        #expect(m.holder?.count == 1)
        try expectFresh()
        #expect(phone.wipeTargets.cancelledNotifications == 1)
        // The phone is as new: a setup code is redeemed again.
        _ = try await m.redeemSetupCode(.secret(service.secret))
        #expect(m.phase == .setup(.newVault))
    }

    /// `device.unlinked{replaced}` (§11.11.5 step 3), authenticated in the session, wipes; another reason does not. Events
    /// are handled in order: when the wipe of the second has run, the first was handled without one. (`vault_deleted`
    /// closes the vault instead: VaultManagerDeletingTests.)
    @Test func anAuthenticatedUnlinkWipes() async throws {
        defer { phone.close() }
        try await setUp()
        service.unlinkThisPhone(reason: "removed")
        service.unlinkThisPhone(reason: "replaced")
        #expect(await eventually { m.phase == .signedOut })
        #expect(m.holder?.count == 1)
        try expectFresh()
    }

    /// `device.unlinked{transferred}` (§6.7.1 step 4) wipes too, once, even when the message arrives twice.
    @Test func aTransferredUnlinkWipesOnce() async throws {
        defer { phone.close() }
        try await setUp()
        service.unlinkThisPhone(reason: "transferred", delivery: .twice)
        #expect(await eventually { m.phase == .signedOut })
        #expect(m.holder?.count == 1)
        try expectFresh()
    }

    /// A `device.unlinked{replaced}` that does not open under the session (altered), or that comes from another relay key
    /// than the vault's, is no proof: nothing is erased. A genuine one after them still wipes, once.
    @Test func anUnauthenticatedUnlinkNeverWipes() async throws {
        defer { phone.close() }
        try await setUp()
        service.unlinkThisPhone(reason: "replaced", delivery: .tampered)
        service.unlinkThisPhone(reason: "replaced", delivery: .wrongSender)
        // A round trip behind them: its answer is collected after them, so they were handled by then.
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.holder?.count == 0 && m.phase == .unlocked && !files.isEmpty)
        service.unlinkThisPhone(reason: "replaced")
        #expect(await eventually { m.phase == .signedOut })
        #expect(m.holder?.count == 1)
    }

    /// No failure is proof: an unlock that cannot reach the member API, whose answer is lost, that the service refuses
    /// (`503`), or a locked vault that answers nothing over the relay, erases nothing.
    @Test func failuresNeverWipe() async throws {
        defer { phone.close() }
        try await lockedVault()
        service.unlockAnswers(.offline, .answerLost, .unavailable)
        for _ in 0..<3 {
            guard case .failed = try await m.unlock(pin: pin) else {
                Issue.record("a failure")
                return
            }
        }
        // The answer lost above opened the vault; locked again, it answers nothing over the relay.
        try await m.lock()
        await #expect(throws: VaultFailure.self) { try await m.ownerChecks.refreshOwnerCheck() }
        #expect(m.holder?.count == 0 && m.phase == .locked && !files.isEmpty)
    }

    /// A session being opened when the wipe starts is stopped and waited for: nothing it writes outlives the erase.
    @Test func aSessionOpeningDuringTheWipeLeavesNothing() async throws {
        defer { phone.close() }
        try await setUp()
        try await phone.restart()
        let opening = Task { try? await m.refresh() }
        await Task.yield()
        try await m.eraseThisPhone()
        await opening.value
        try expectFresh()
    }

    /// A wipe resumed at the next start also leaves no owner-check state in memory, and nothing reads the files before it.
    @Test func aResumedWipeClearsTheOwnerCheckToo() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.ownerChecks.ownerCheck != nil)
        try LocalWipe(targets: phone.wipeTargets).begin()
        try await phone.restart()
        m.resumePendingWipe()
        m.reloadLocalState()
        #expect(m.ownerChecks.ownerCheck == nil)
        try await m.refresh()
        try expectFresh()
    }

    /// A request the old manager still awaited at a restart (a process death ends it) writes nothing once the new
    /// manager's wipe erased the files, even when its answer arrives afterwards; the old manager starts nothing more.
    @Test func aRequestOfTheOldManagerWritesNothingAfterTheRestart() async throws {
        defer { phone.close() }
        try await setUp()
        let old = m
        let statuses = service.requestsSeen.filter { $0 == "vault.status" }.count
        service.holdMessages = true
        let request = Task { try? await old.ownerChecks.refreshOwnerCheck() }
        #expect(await eventually { service.requestsSeen.filter { $0 == "vault.status" }.count > statuses })
        try LocalWipe(targets: phone.wipeTargets).begin()
        try await phone.restart()
        m.resumePendingWipe()
        m.reloadLocalState()
        try await m.refresh()
        service.holdMessages = false
        await request.value
        // The halted manager opens no session again.
        await #expect(throws: VaultFailure.self) { _ = try await old.openSession() }
        try expectFresh()
    }

    /// An unreadable answer is no proof: nothing is erased (``VaultManagerUnlockTests``); the member's erase is, with the
    /// files earlier builds wrote (``VaultFiles/retired``) when one is still there.
    @Test func theMembersEraseWipesThePhone() async throws {
        defer { phone.close() }
        try await lockedVault()
        for name in VaultFiles.retired { try Data([1]).write(to: phone.directory.appendingPathComponent(name)) }
        service.unlockAnswers(.unreadable)
        #expect(try await m.unlock(pin: pin) == .failed(.other, code: "unreadable_result"))
        #expect(!files.isEmpty && m.phase == .locked)
        try await m.eraseThisPhone()
        try expectFresh()
    }

    /// A wipe that cannot finish says so, never as a clean welcome screen; nothing opens a session meanwhile; "Try again"
    /// runs it again.
    @Test func aWipeThatCannotFinishSaysSoAndTryAgainFinishesIt() async throws {
        defer { phone.close() }
        try await setUp()
        phone.wipeTargets.keyStuck = true
        try await m.eraseThisPhone()
        #expect(m.phase == .unreachable(.eraseFailed, longUnreachable: false))
        #expect(files == [LocalWipe.marker], "everything but the marker is gone already")
        // Nothing of the old vault opens again.
        #expect(await vaultFailure { _ = try await m.preflight() }?.kind == .eraseFailed)
        try await m.refresh()
        #expect(m.phase == .unreachable(.eraseFailed, longUnreachable: false))
        phone.wipeTargets.keyStuck = false
        try await m.refresh()
        try expectFresh()
    }

    /// A wipe the process did not live to finish is finished at the next start, before anything reads local state.
    @Test func anInterruptedWipeFinishesAtTheNextStart() async throws {
        defer { phone.close() }
        try await setUp()
        try LocalWipe(targets: phone.wipeTargets).begin()
        try await phone.restart()
        try await m.refresh()
        try expectFresh()
    }

    /// "Erase VettID's data on this phone" (vettid-android `AppDataClear`), offered only after a wipe that did not finish:
    /// local only; true when nothing is left.
    @Test func erasingTheDataAfterAFailedWipe() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await !m.clearAppData(), "not offered while no wipe failed")
        #expect(m.phase == .unlocked)
        phone.wipeTargets.keyStuck = true
        try await m.eraseThisPhone()
        #expect(await !m.clearAppData(), "the key is still stuck")
        phone.wipeTargets.keyStuck = false
        #expect(await m.clearAppData())
        try expectFresh()
    }

    /// The wipe's in-memory resets of the app (the app lock, a setup link) run once per wipe.
    @Test func theAppsResetsRun() async throws {
        defer { phone.close() }
        try await setUp()
        let runs = Runs()
        m.onWipe { runs.count += 1 }
        try await m.eraseThisPhone()
        #expect(runs.count == 1)
    }

    @MainActor
    final class Runs {
        var count = 0
    }
}
