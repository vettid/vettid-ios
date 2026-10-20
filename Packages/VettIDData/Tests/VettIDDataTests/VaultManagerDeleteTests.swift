import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// Delete vault (`vault.delete`, VAULT-MESSAGING §12.5) end to end against ``FakeVaultService``, which answers it as
/// vettid-vault does and then deletes itself (its mailbox refuses every deposit, `device.unlinked{vault_deleted}`, and
/// the member API's "no vault"). After the vault's answer VettID's data on this phone is erased (``WipeRun``). A lost answer (chosen; not
/// in the spec): the member API's explicit "no vault" means it applied; otherwise it is undecided, said so, checked again
/// without sending anything, or tried again. Mirrors vettid-android's `deleteVault` tests.
@MainActor
@Suite(.serialized) struct VaultManagerDeleteTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        service.stampsOnVaultClock = true
        phone = try TestVaultPhone(service: service, requestTimeout: TestVaultPhone.shortRequestTimeout)
    }

    var m: VaultManager { phone.manager }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    func delete(pin: String? = nil, password: String? = nil) async -> VaultFailure? {
        await vaultFailure { try await m.deleteVault(pin: pin ?? self.pin, password: password ?? self.password) }
    }

    /// The files left in the phone's data directory.
    var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: phone.directory.path)) ?? [] }

    /// As freshly installed: no file, no key, signed out.
    func expectWiped() throws {
        #expect(m.phase == .signedOut)
        #expect(files.isEmpty, "files left: \(files)")
        #expect(try !phone.wipeTargets.keysLeft())
        #expect(m.account == nil && !m.usesPhoneSecret)
    }

    /// The phrase beside the blob, the PIN and the password: the vault deletes itself and VettID's data on this phone is erased; the welcome
    /// screen follows, and a new setup code can be redeemed.
    @Test func aDeletionWipesThisPhone() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await delete() == nil)
        let sent = try #require(service.deletes.first)
        #expect(sent.confirm == "delete my vault" && sent.pin == pin && sent.password == password)
        #expect(service.vaultDeleted)
        try expectWiped()
        _ = try await m.redeemSetupCode(.secret(service.secret))
        #expect(m.phase == .setup(.newVault))
    }

    /// A refusal is shown as it is; nothing is deleted or wiped.
    @Test func aRefusalChangesNothing() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await delete(password: "wrong")?.kind == .badPassword)
        #expect(await delete(pin: "999999")?.kind == .badPin)
        #expect(!service.vaultDeleted && m.phase == .unlocked && m.usesPhoneSecret && !files.isEmpty)
    }

    /// The answer lost after the vault deleted itself: nothing answers any more, the member API says there is no vault,
    /// and VettID's data on this phone is erased as after the answer.
    @Test func aLostAnswerWithTheVaultGoneWipes() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typeVaultDelete])
        #expect(await delete() == nil)
        #expect(service.vaultDeleted && service.deletes.count == 1)
        try expectWiped()
    }

    /// The answer lost while the member API still lists the vault: the vault's `device.unlinked{vault_deleted}` says
    /// that the deletion applied, so the phone shows "being deleted" (IOS-PLAN §4.2) rather than "not confirmed"; nothing
    /// more goes to the vault, and once the API no longer lists the vault, Check again erases VettID's data.
    @Test func aLostAnswerTheApiStillListsIsBeingDeleted() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typeVaultDelete])
        service.statusLagsDeletion = true
        _ = await delete()
        #expect(await eventually { m.phase == .deleting })
        #expect(service.vaultDeleted && m.record.value.deleting != nil)
        let seen = service.requestsSeen.count
        #expect(await m.checkDeletionAgain() == .listed)
        service.statusLagsDeletion = false
        #expect(await m.checkDeletionAgain() == .gone)
        #expect(service.requestsSeen.count == seen && service.deletes.count == 1, "nothing sent to the vault")
        try expectWiped()
        #expect(m.vaultDeletedNotice)
    }

    /// The answer lost while the member API still lists the vault, and no `device.unlinked{vault_deleted}` reaches this
    /// phone: undecided (`delete_unconfirmed`), nothing wiped. A check sends nothing to the vault and finds it still
    /// listed; once the API says there is no vault, the check erases VettID's data.
    @Test func aLostAnswerTheApiStillListsIsUnconfirmedUntilChecked() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typeVaultDelete])
        service.holdsDeletionUnlink = true
        service.statusLagsDeletion = true
        let f = await delete()
        #expect(f?.kind == .noResponse && f?.code == VaultManager.codeDeleteUnconfirmed)
        #expect(service.vaultDeleted && m.usesPhoneSecret && !files.isEmpty && m.phase == .unlocked)
        let seen = service.requestsSeen.count
        #expect(try await m.checkVaultDeleted() == .undecided)
        service.statusLagsDeletion = false
        #expect(try await m.checkVaultDeleted() == .deleted)
        #expect(service.requestsSeen.count == seen && service.deletes.count == 1, "nothing sent to the vault")
        try expectWiped()
    }

    /// The request lost on its way: undecided, the vault still there; the member's new try deletes it.
    @Test func aLostRequestIsUnconfirmedAndATryAgainDeletes() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseRequests([VaultApi.typeVaultDelete])
        #expect(await delete()?.code == VaultManager.codeDeleteUnconfirmed)
        #expect(!service.vaultDeleted && m.phase == .unlocked)
        #expect(try await m.checkVaultDeleted() == .undecided)
        service.loseRequests([])
        #expect(await delete() == nil)
        #expect(service.vaultDeleted)
        try expectWiped()
    }

    /// The member API's "no vault" wipes nothing unless this phone's own deletion went unanswered: the root's "no vault"
    /// screen decides then (``VaultManager/forgetMissingVault()``).
    @Test func noVaultWithoutALostDeletionWipesNothing() async throws {
        defer { phone.close() }
        try await setUp()
        service.status("unlocked", noVault: true)
        #expect(try await m.checkVaultDeleted() == .undecided)
        #expect(m.usesPhoneSecret && !files.isEmpty)
    }

    /// `vault.delete` is a credential operation (§11.14.9 step 2): refused before anything is sent while a PIN change is
    /// unresolved.
    @Test func aDeletionWaitsForAnUnresolvedChange() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseRequests(["pin.change"])
        _ = await vaultFailure { try await m.changePin(pin: pin, newPin: "518293", password: password) }
        #expect(await delete()?.kind == .changeChecking)
        #expect(service.deletes.isEmpty && !service.vaultDeleted)
    }

    // MARK: - A deletion waiting in a locked vault (chosen; not in the spec)

    /// The vault's clock and the phone's, moved together past a request's `exp` by more than a minute.
    func pastExp() {
        let t = ChangeRequest.validFor + 2 * VaultManager.decidedAfterExp
        service.advanceVaultClock(t)
        phone.clockAhead = t
        phone.uptimeAhead = t
    }

    /// The vault locked behind the app's back; the deletion waits in its mailbox, unanswered, and the member API still
    /// lists the vault: undecided. The next unlock, before `exp`, lets the waiting copy apply; its
    /// `device.unlinked{vault_deleted}` closes the open app for "being deleted" (IOS-PLAN §4.2), and the next read (a
    /// return to the foreground) finds the vault gone and erases VettID's data.
    @Test func aDeletionWaitingInALockedVaultAppliesAtTheUnlock() async throws {
        defer { phone.close() }
        try await setUp()
        service.lockByItself(reason: "test")
        #expect(await delete()?.code == VaultManager.codeDeleteUnconfirmed)
        #expect(!service.vaultDeleted && service.deletes.isEmpty)
        _ = try await m.unlock(pin: pin)
        #expect(await eventually { service.vaultDeleted })
        #expect(await eventually { m.phase == .deleting })
        // The bound counts from the request's `exp` (10 minutes on the vault's clock) plus 2 minutes, when later.
        let d = try #require(m.deletion)
        #expect(d.until.timeIntervalSince(d.since) > VaultManager.deletingBound)
        m.onForeground()
        #expect(await eventually { m.phase == .signedOut })
        try expectWiped()
    }

    /// The deletion's `device.unlinked{vault_deleted}` read while the unlock waits for its answer (its slot answers late):
    /// "being deleted" at once, and the unlock's end never puts the open app over it.
    @Test func anUnlinkDuringAnUnlockWins() async throws {
        defer { phone.close() }
        try await setUp()
        service.lockByItself(reason: "test")
        #expect(await delete()?.code == VaultManager.codeDeleteUnconfirmed)
        service.slotQueuedAfterDeletion = .max
        service.statusLagsDeletion = true
        let unlock = Task { try await m.unlock(pin: pin) }
        #expect(await eventually { m.phase == .deleting }, "while the unlock waits for its answer")
        service.slotQueuedAfterDeletion = 0
        _ = try? await unlock.value
        #expect(m.phase == .deleting && m.session == nil)
        service.statusLagsDeletion = false
        #expect(await m.checkDeletionAgain() == .gone)
        try expectWiped()
    }

    var noVault: AppPhase { .unreachable(.noVault, longUnreachable: false) }

    /// A `device.unlinked` that has the phase read again (reason `removed`) read while the unlock waits for its answer:
    /// the read ends before the unlock does, and the unlock's end never puts the open app over its "no vault".
    @Test func anUnlinkReadEndingBeforeTheUnlockWins() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.lock()
        service.unlockAnswers(.held)
        let unlocks = service.unlocks.count
        let unlock = Task { try await m.unlock(pin: pin) }
        #expect(await eventually { service.unlocks.count > unlocks })
        service.status("unlocked", noVault: true)
        service.unlinkThisPhone(reason: "removed")
        #expect(await eventually { m.phase == noVault }, "read while the unlock waits for its answer")
        service.releaseHeldUnlock()
        #expect(try await unlock.value == .success)
        #expect(m.phase == noVault)
    }

    /// The same with the read still on its way when the unlock's answer comes in: it ends after the unlock, and "no
    /// vault" follows all the same.
    @Test func anUnlinkReadEndingAfterTheUnlockWins() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.lock()
        service.unlockAnswers(.held)
        let unlocks = service.unlocks.count
        let unlock = Task { try await m.unlock(pin: pin) }
        #expect(await eventually { service.unlocks.count > unlocks })
        service.status("unlocked", noVault: true)
        service.holdStatusReads()
        service.unlinkThisPhone(reason: "removed")
        #expect(await eventually { service.heldStatusReads == 1 }, "the read for device.unlinked, held")
        service.releaseHeldUnlock()
        #expect(await eventually { m.phase == .unlocked || service.heldStatusReads == 2 })
        service.releaseStatusReads()
        #expect(try await unlock.value == .success)
        #expect(await eventually { m.phase == noVault })
    }

    /// The same past the deletion's `exp`: the vault is still listed more than a minute after it, so it was not deleted
    /// and never will be; the unlock's waiting copy is dropped unanswered.
    @Test func aDeletionWaitingPastItsExpIsNotDeleted() async throws {
        defer { phone.close() }
        try await setUp()
        service.lockByItself(reason: "test")
        #expect(await delete()?.code == VaultManager.codeDeleteUnconfirmed)
        #expect(try await m.checkVaultDeleted() == .undecided, "before exp: undecided")
        pastExp()
        #expect(try await m.checkVaultDeleted() == .notDeleted)
        #expect(try await m.checkVaultDeleted() == .undecided, "said once; nothing pending any more")
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(!service.vaultDeleted && service.deletes.isEmpty && m.usesPhoneSecret)
    }

    /// "Not deleted" rests only on the vault's own time: with the phone's clock 15 minutes ahead and the session reopened
    /// (no vault time on the new device), the check stays undecided; only the monotonic clock past the deadline decides.
    @Test func notDeletedNeverRestsOnThePhonesClock() async throws {
        defer { phone.close() }
        try await setUp()
        service.lockByItself(reason: "test")
        #expect(await delete()?.code == VaultManager.codeDeleteUnconfirmed)
        m.stopCollecting()
        phone.clockAhead = 15 * 60
        #expect(try await m.checkVaultDeleted() == .undecided)
        #expect(m.session?.device.knowsVaultTime != true, "no vault time on a reopened session")
        phone.uptimeAhead = ChangeRequest.validFor + 2 * VaultManager.decidedAfterExp
        #expect(try await m.checkVaultDeleted() == .notDeleted)
    }

    /// A refusal to a later try means that the earlier copy, handled before it, deleted nothing: nothing stays pending.
    @Test func anAnswerToALaterTryEndsTheEarlierOne() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseRequests([VaultApi.typeVaultDelete])
        #expect(await delete()?.code == VaultManager.codeDeleteUnconfirmed)
        service.loseRequests([])
        #expect(await delete(password: "wrong")?.kind == .badPassword)
        service.status("unlocked", noVault: true)
        #expect(try await m.checkVaultDeleted() == .undecided && m.usesPhoneSecret)
    }

    /// A build that cannot wipe: the vault's keys are forgotten and the record reset, as vettid-android does; the welcome
    /// screen follows and a new setup code can be redeemed.
    @Test func aDeletionWithoutAWiperForgetsTheVault() async throws {
        let service = try FakeVaultService()
        let phone = try TestVaultPhone(service: service, requestTimeout: TestVaultPhone.shortRequestTimeout, wipes: false)
        defer { phone.close() }
        let m = phone.manager
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        try await m.deleteVault(pin: pin, password: password)
        #expect(service.vaultDeleted && m.phase == .signedOut && !m.usesPhoneSecret && m.record.value.vaultID.isEmpty)
        _ = try await m.redeemSetupCode(.secret(service.secret))
        #expect(m.phase == .setup(.newVault))
    }
}
