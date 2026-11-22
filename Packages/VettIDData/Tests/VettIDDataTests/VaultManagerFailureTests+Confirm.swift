import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// A provisional vault after a restart (VAULT-MESSAGING §11.3): who confirms it, and when.
extension VaultManagerFailureTests {
    /// Enrolled here, the credential made, its confirmation lost; then a restart.
    func provisionalRestarted() async throws {
        try await redeemed()
        try await m.enroll(pin: "402817") { _ in }
        service.failNext("vault.enroll.confirm")
        _ = await vaultFailure { try await m.createCredential(password: "correct horse battery", backup: true, pin: "402817") { _ in } }
        try await phone.restart()
    }

    /// Then a start whose read a lock overtakes: the vault found locked, not confirmed.
    func lockedAtTheStart() async throws {
        try await provisionalRestarted()
        service.holdStatusReads()
        let reading = Task { try await m.refresh() }
        #expect(await eventually { service.heldStatusReads == 1 })
        let heard = m.locksHeard
        service.sendEvent("vault.locking", #"{"reason":"test"}"#)
        #expect(await eventually { m.locksHeard != heard })
        service.releaseStatusReads()
        try await reading.value
        #expect(m.phase == .locked && !service.confirmed)
    }

    /// Then an unlock whose confirmation (after the opening) fails: on "finishing" all the same, not confirmed.
    func finishingUnconfirmed() async throws {
        try await lockedAtTheStart()
        service.failNext("vault.enroll.confirm")
        let sent = confirmsSent
        #expect(try await m.unlock(pin: "402817") == .success)
        #expect(await eventually { confirmsSent == sent + 1 && m.confirming == nil })
        #expect(m.phase == .setup(.finishing) && !service.confirmed)
    }

    var confirmsSent: Int { service.requestsSeen.filter { $0 == "vault.enroll.confirm" }.count }

    /// A lock asked for before "Finish": the gate would not end the setup, so nothing is confirmed.
    @Test func finishingAfterALockSendsNoConfirmation() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        let sent = confirmsSent
        try await m.lock()
        _ = await vaultFailure { try await m.finishSetup() }
        #expect(confirmsSent == sent && !service.confirmed)
    }

    /// Not on the final onboarding screen: the vault open, its session too, and only the gate keeps the confirmation back.
    @Test func finishingOffTheFinishingStepSendsNoConfirmation() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        let sent = confirmsSent
        m.phase = .setup(.needsCredential)
        _ = await vaultFailure { try await m.finishSetup() }
        #expect(confirmsSent == sent && !service.confirmed)
        #expect(m.phase == .setup(.needsCredential), "the gate leaves the phase as it is")
    }

    /// Only the phone whose enrollment made the vault confirms it: another is refused, as before.
    @Test func finishingOnAnotherPhoneSendsNoConfirmation() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        try m.record.update(since: m.record.generation) { $0.enrolledHere = false }
        let sent = confirmsSent
        #expect(await vaultFailure { try await m.finishSetup() }?.code == VaultManager.codeEnrollUnconfirmed)
        #expect(confirmsSent == sent && !service.confirmed)
    }

    /// A confirmation that fails is said, and the setup stays on "finishing" for another try.
    @Test func aFailedConfirmationAtFinishingKeepsTheStep() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        service.failNext("vault.enroll.confirm")
        #expect(await vaultFailure { try await m.finishSetup() } != nil)
        #expect(m.phase == .setup(.finishing) && !service.confirmed)
        try await m.finishSetup()
        #expect(service.confirmed && m.phase == .unlocked)
    }

    /// A lock heard while the start's confirmation is on its way, which then fails: Locked, not "can't connect".
    @Test func aLockDuringTheStartsConfirmationGivesLocked() async throws {
        defer { phone.close() }
        try await provisionalRestarted()
        service.lockBefore("vault.enroll.confirm")
        service.refuse("vault.enroll.confirm", with: "internal", times: 1)
        // The refusal waits until the lock was heard: they reach the main actor by separate hops.
        service.holdAnswers(to: "vault.enroll.confirm")
        let heard = m.locksHeard
        let reading = Task { try await m.refresh() }
        #expect(await eventually { m.locksHeard != heard })
        service.releaseHeldAnswers()
        try await reading.value
        #expect(m.phase == .locked, "\(m.phase)")
        #expect(!service.confirmed)
    }

    /// "Finish" opens the session as it is now: one stopped meanwhile (a background, say) does not leave the vault
    /// unconfirmed.
    @Test func finishingWithoutASessionOpensOneAndConfirms() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        m.stopCollecting()
        #expect(m.session == nil)
        try await m.finishSetup()
        #expect(service.confirmed && m.phase == .unlocked)
    }

    // MARK: - One confirmation at a time

    /// Two status reads that find the vault open and unconfirmed [first] has started confirming: the second joins it.
    func twoReads(_ first: @escaping @MainActor () async throws -> Void) async throws {
        service.holdAnswers(to: "vault.enroll.confirm")
        let one = Task { try await first() }
        #expect(await eventually { service.heldAnswers == 1 })
        let two = Task { try await m.refresh() }
        #expect(await eventually { m.confirmationsJoined == 1 }, "the second read joins the confirmation on its way")
        service.releaseHeldAnswers()
        try await one.value
        try await two.value
    }

    /// The start's read and the return to the foreground's, both finding the vault open: one confirmation.
    @Test func twoReadsAtTheStartSendOneConfirmation() async throws {
        defer { phone.close() }
        try await provisionalRestarted()
        let sent = confirmsSent
        try await twoReads { try await m.refresh() }
        #expect(confirmsSent == sent + 1 && service.confirmed)
        #expect(m.phase == .setup(.finishing), "\(m.phase)")
    }

    /// A read beside "Finish": one confirmation, and the setup ends.
    @Test func aReadBesideFinishSendsOneConfirmation() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        let sent = confirmsSent
        try await twoReads { try await m.finishSetup() }
        #expect(confirmsSent == sent + 1 && service.confirmed)
        #expect(m.phase == .unlocked, "\(m.phase)")
    }

    /// The shared confirmation fails: both reads say that failure (not one "can't connect" over another's open vault), and
    /// the next read confirms.
    @Test func aSharedConfirmationsFailureIsEachReadsOwn() async throws {
        defer { phone.close() }
        try await provisionalRestarted()
        let sent = confirmsSent
        service.refuse("vault.enroll.confirm", with: "internal", times: 1)
        try await twoReads { try await m.refresh() }
        #expect(confirmsSent == sent + 1 && !service.confirmed)
        guard case .unreachable = m.phase else { Issue.record("\(m.phase)"); return }
        try await m.refresh()
        #expect(confirmsSent == sent + 2 && service.confirmed)
        #expect(m.phase == .setup(.finishing), "\(m.phase)")
    }

    /// A vault found locked at the restart, then unlocked: the unlock confirms it, once, and "Finish" sends nothing more.
    @Test func anUnlockConfirmsAProvisionalVault() async throws {
        defer { phone.close() }
        try await lockedAtTheStart()
        let sent = confirmsSent
        #expect(try await m.unlock(pin: "402817") == .success)
        #expect(m.phase == .setup(.finishing), "\(m.phase)")
        #expect(await eventually { service.confirmed && m.confirming == nil })
        #expect(confirmsSent == sent + 1)
        try await m.finishSetup()
        #expect(confirmsSent == sent + 1 && m.phase == .unlocked)
    }

    /// Only the phone whose enrollment made the vault confirms it at an unlock.
    @Test func anUnlockOnAnotherPhoneSendsNoConfirmation() async throws {
        defer { phone.close() }
        try await lockedAtTheStart()
        try m.record.update(since: m.record.generation) { $0.enrolledHere = false }
        let sent = confirmsSent
        #expect(try await m.unlock(pin: "402817") == .success)
        for _ in 0..<20 { await Task.yield() } // the unlock's confirmation, had it begun, would be on its way now
        #expect(m.confirming == nil && confirmsSent == sent && !service.confirmed)
    }

    /// The unlock does not wait for its confirmation: it opens while the answer is on its way, and "Finish" joins it.
    @Test func finishJoinsTheUnlocksConfirmation() async throws {
        defer { phone.close() }
        try await lockedAtTheStart()
        let sent = confirmsSent
        service.holdAnswers(to: "vault.enroll.confirm")
        #expect(try await m.unlock(pin: "402817") == .success)
        #expect(m.phase == .setup(.finishing), "\(m.phase)")
        #expect(await eventually { service.heldAnswers == 1 })
        let finishing = Task { try await m.finishSetup() }
        #expect(await eventually { m.confirmationsJoined == 1 })
        service.releaseHeldAnswers()
        try await finishing.value
        #expect(confirmsSent == sent + 1 && service.confirmed && m.phase == .unlocked)
    }

    /// A lock heard while the unlock's confirmation is on its way: Locked, whatever the confirmation's answer.
    @Test func aLockDuringTheUnlocksConfirmationGivesLocked() async throws {
        defer { phone.close() }
        try await lockedAtTheStart()
        service.lockBefore("vault.enroll.confirm")
        service.holdAnswers(to: "vault.enroll.confirm")
        let heard = m.locksHeard
        #expect(try await m.unlock(pin: "402817") == .success)
        #expect(await eventually { m.locksHeard != heard })
        service.releaseHeldAnswers()
        #expect(await eventually { m.phase == .locked && m.confirming == nil }, "\(m.phase)")
    }

    /// A confirmation on a session dropped since (the app went to the background): "Finish" in the session opened again
    /// sends its own rather than wait for an answer the old session will never collect.
    @Test func finishDoesNotJoinADroppedSessionsConfirmation() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        service.holdAnswers(to: "vault.enroll.confirm")
        let reading = Task { try await m.refresh() }
        #expect(await eventually { service.heldAnswers == 1 })
        m.stopCollecting()
        service.releaseHeldAnswers()
        try await m.finishSetup()
        #expect(m.confirmationsJoined == 0 && service.confirmed && m.phase == .unlocked)
        reading.cancel()
    }

    /// A dropped session's confirmation that ends late does not take the place of the one on its way in the session opened
    /// again: a read there still joins that one.
    @Test func aDroppedSessionsConfirmationEndingLateLeavesTheNewOne() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        service.holdAnswers(to: "vault.enroll.confirm")
        let old = Task { try await m.refresh() }
        #expect(await eventually { service.heldAnswers == 1 })
        m.stopCollecting()
        let finishing = Task { try await m.finishSetup() }
        #expect(await eventually { service.heldAnswers == 2 })
        old.cancel()
        _ = try? await old.value
        let reading = Task { try await m.refresh() }
        #expect(await eventually { m.confirmationsJoined == 1 }, "the read joins the new session's confirmation")
        service.releaseHeldAnswers()
        try await finishing.value
        try await reading.value
        #expect(service.confirmed && m.phase == .unlocked)
    }

    /// A read while the credential's step confirms the vault joins that confirmation.
    @Test func aReadDuringTheCredentialsConfirmationJoinsIt() async throws {
        defer { phone.close() }
        try await redeemed()
        try await m.enroll(pin: "402817") { _ in }
        service.holdAnswers(to: "vault.enroll.confirm")
        let creating = Task { try await m.createCredential(password: "correct horse battery", backup: true, pin: "402817") { _ in } }
        #expect(await eventually { service.heldAnswers == 1 })
        let reading = Task { try await m.refresh() }
        #expect(await eventually { m.confirmationsJoined == 1 })
        service.releaseHeldAnswers()
        try await creating.value
        try await reading.value
        #expect(confirmsSent == 1 && service.confirmed)
    }

    /// A read whose session was dropped while its status read was on its way (a background and a return): it sends no
    /// confirmation on the old session, publishes nothing, and "Finish" in the new one sends its own.
    @Test func aReadOfADroppedSessionSendsNoConfirmation() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        let sent = confirmsSent
        let reads = { service.requestsSeen.filter { $0 == "settings.get" }.count }
        let readsBefore = reads()
        service.holdStatusReads()
        let reading = Task { try await m.refresh() }
        #expect(await eventually { service.heldStatusReads == 1 })
        m.stopCollecting()
        _ = try await m.openSession()
        service.releaseStatusReads()
        try await reading.value
        #expect(reads() == readsBefore && confirmsSent == sent, "nothing sent on the old session")
        #expect(m.phase == .setup(.finishing), "\(m.phase)")
        try await m.finishSetup()
        #expect(m.confirmationsJoined == 0 && confirmsSent == sent + 1 && m.phase == .unlocked)
    }

    /// The confirmation's sender is cancelled (a screen's task) while "Finish" waits for it: "Finish" goes on and sends it.
    @Test func aCancelledSenderDoesNotFailFinish() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        service.holdAnswers(to: "vault.enroll.confirm")
        let reading = Task { try await m.refresh() }
        #expect(await eventually { service.heldAnswers == 1 })
        let finishing = Task { try await m.finishSetup() }
        #expect(await eventually { m.confirmationsJoined == 1 })
        reading.cancel()
        _ = try? await reading.value
        service.releaseHeldAnswers()
        try await finishing.value
        #expect(service.confirmed && m.phase == .unlocked)
    }

    /// An unlock while the previous unlock's confirmation is on its way, the vault having locked meanwhile: it sends its
    /// own rather than wait for the one the locked vault keeps in its mailbox.
    @Test func anUnlockAfterALockDoesNotJoinTheLastOnesConfirmation() async throws {
        defer { phone.close() }
        try await lockedAtTheStart()
        service.holdAnswers(to: "vault.enroll.confirm")
        #expect(try await m.unlock(pin: "402817") == .success)
        #expect(await eventually { service.heldAnswers == 1 })
        let heard = m.locksHeard
        service.sendEvent("vault.locking", #"{"reason":"test"}"#)
        #expect(await eventually { m.locksHeard != heard && m.phase == .locked })
        #expect(try await m.unlock(pin: "402817") == .success)
        #expect(await eventually { service.heldAnswers == 2 }, "the second unlock sends its own")
        #expect(m.confirmationsJoined == 0)
        service.releaseHeldAnswers()
        #expect(await eventually { service.confirmed && m.confirming == nil })
    }

    /// A start's read whose session dropped while its status read was on its way: the phone, still on Starting, reads
    /// again in the live session.
    @Test func aStartsReadOfADroppedSessionReadsAgain() async throws {
        defer { phone.close() }
        try await provisionalRestarted()
        service.holdStatusReads()
        let reading = Task { try await m.refresh() }
        #expect(await eventually { service.heldStatusReads == 1 })
        m.stopCollecting()
        _ = try await m.openSession()
        service.releaseStatusReads()
        try await reading.value
        #expect(m.phase == .setup(.finishing) && service.confirmed, "\(m.phase)")
    }

    /// The confirmation after an unlock judges a lock by its time, as the opening does: the `vault.locking` of the opening
    /// before (which the unlock of a running vault makes) heard only after the opening, before the confirmation's task
    /// starts, does not stop it. A lock after the opening, a probe's, or a lock asked for since does; with no opening moment,
    /// any lock heard since does.
    @Test func confirmAfterUnlockJudgesLocksByTheirTime() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        let (locks, heard) = (m.lockGeneration, m.locksHeard)
        // (The times are after the locks heard so far: a lock heard only ever moves the latest forward.)
        let openedAt = (heard.latest ?? Date()).addingTimeInterval(10)
        #expect(m.confirmAfterUnlockDue(locks: locks, openedAt: openedAt, heard: heard))
        // The opening before's lock, relayed late: newer than every lock heard so far, older than this opening.
        m.noteLockSeen(at: openedAt.addingTimeInterval(-5))
        #expect(m.locksHeard != heard)
        #expect(m.confirmAfterUnlockDue(locks: locks, openedAt: openedAt, heard: heard))
        // Without the opening's moment, any lock heard since counts.
        #expect(!m.confirmAfterUnlockDue(locks: locks, openedAt: nil, heard: heard))
        // A lock asked for since.
        #expect(!m.confirmAfterUnlockDue(locks: locks - 1, openedAt: openedAt, heard: heard))
        // A lock after the opening.
        m.noteLockSeen(at: openedAt.addingTimeInterval(1))
        #expect(!m.confirmAfterUnlockDue(locks: locks, openedAt: openedAt, heard: heard))
        // A probe that found the vault locked, whatever the times.
        let now = m.locksHeard
        m.noteProbeLock()
        #expect(!m.confirmAfterUnlockDue(locks: locks, openedAt: openedAt.addingTimeInterval(60), heard: now))
        #expect(m.phase == .setup(.finishing))
    }

    /// "Finish" joins the confirmation on its way though the `vault.locking` of the opening before is heard only after it
    /// began, stamped as the opening is (the vault stamps both in the same millisecond): the confirmation is sent once.
    @Test func finishJoinsAConfirmationThoughALateOldLockIsHeard() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        let openedAt = try #require(m.lockNotices.openedAt)
        // As if that lock had not reached this phone yet: the last one heard is older.
        m.locksHeard.latest = openedAt.addingTimeInterval(-60)
        service.holdAnswers(to: "vault.enroll.confirm")
        let sent = confirmsSent
        let reading = Task { try await m.refresh() }
        #expect(await eventually { service.heldAnswers == 1 })
        #expect(m.confirming?.openedAt == openedAt)
        // It arrives now.
        m.noteLockSeen(at: openedAt)
        #expect(m.locksHeard.latest == openedAt)
        let finishing = Task { try await m.finishSetup() }
        #expect(await eventually { m.confirmationsJoined == 1 })
        service.releaseHeldAnswers()
        try await finishing.value
        try await reading.value
        #expect(confirmsSent == sent + 1 && service.confirmed && m.phase == .unlocked, "\(m.phase)")
    }

    /// A lock after the opening a confirmation began under, heard only after it began, is not joined: that vault closed,
    /// so "Finish" sends its own.
    @Test func finishDoesNotJoinAConfirmationALaterLockClosed() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        service.holdAnswers(to: "vault.enroll.confirm")
        let sent = confirmsSent
        let reading = Task { try await m.refresh() }
        #expect(await eventually { service.heldAnswers == 1 })
        let openedAt = try #require(m.confirming?.openedAt)
        let start = try #require(m.confirming?.start)
        #expect(openedAt < start.at && start.onVaultClock)
        // Timed after the opening and before the confirmation began; heard now.
        m.noteLockSeen(at: openedAt.addingTimeInterval(start.at.timeIntervalSince(openedAt) / 2))
        let finishing = Task { try await m.finishSetup() }
        #expect(await eventually { service.heldAnswers == 2 })
        service.releaseHeldAnswers()
        try await finishing.value
        _ = try? await reading.value
        #expect(m.confirmationsJoined == 0 && confirmsSent == sent + 2 && service.confirmed)
    }

    /// The join's rule, judged directly: a lock after the opening refuses it, heard before the confirmation began or after;
    /// with the opening's moment unknown, any lock heard since it began does; nothing heard since, it joins.
    @Test func theJoinJudgesLocksFromTheOpening() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        let heard = m.locksHeard
        let base = (heard.latest ?? Date()).addingTimeInterval(10)
        let done = Task<Void, any Error> {}
        func began(openedAt: Date?) -> VaultManager.Confirming {
            VaultManager.Confirming(done: done, session: m.sessionGeneration, locks: m.lockGeneration, start: m.readStart(),
                                    openedAt: openedAt)
        }
        let known = began(openedAt: base)
        let unknown = began(openedAt: nil)
        #expect(!m.lockedSinceConfirming(known) && !m.lockedSinceConfirming(unknown))
        // A lock after the opening, already heard when a confirmation began: refused all the same.
        m.noteLockSeen(at: base.addingTimeInterval(1))
        #expect(m.lockedSinceConfirming(began(openedAt: base)))
        // Heard since an unknown opening's confirmation began: refused.
        #expect(m.lockedSinceConfirming(unknown))
        // The opening before's lock, heard since: a known opening still joins, an unknown one does not.
        let later = began(openedAt: base.addingTimeInterval(10))
        let unknownLater = began(openedAt: nil)
        m.noteLockSeen(at: base.addingTimeInterval(5))
        #expect(!m.lockedSinceConfirming(later) && m.lockedSinceConfirming(unknownLater))
    }

    /// (Release L) A `vault.locking` naming the current opening is a lock after it whatever its time, the opening's own
    /// millisecond included: it stops the unlock's confirmation and refuses the join.
    @Test func aLockNamingTheCurrentOpeningCountsAfterIt() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        let openedAt = try #require(m.lockNotices.openedAt)
        let (locks, heard) = (m.lockGeneration, m.locksHeard)
        let done = Task<Void, any Error> {}
        let c = VaultManager.Confirming(done: done, session: m.sessionGeneration, locks: locks, start: m.readStart(),
                                        openedAt: openedAt)
        m.noteLockSeen(at: openedAt)
        #expect(m.confirmAfterUnlockDue(locks: locks, openedAt: openedAt, heard: heard) && !m.lockedSinceConfirming(c))
        m.noteLockSeen(at: openedAt, namingCurrent: true)
        #expect(!m.confirmAfterUnlockDue(locks: locks, openedAt: openedAt, heard: heard))
        #expect(m.lockedSinceConfirming(c))
    }

    /// The unlock passes its result's time to its confirmation, which carries it into the join.
    @Test func theUnlockPassesTheOpeningsTimeToItsConfirmation() async throws {
        defer { phone.close() }
        try await lockedAtTheStart()
        service.holdAnswers(to: "vault.enroll.confirm")
        #expect(try await m.unlock(pin: "402817") == .success)
        #expect(await eventually { service.heldAnswers == 1 })
        let openedAt = try #require(m.lastConfirmOpenedAt)
        #expect(openedAt == m.lockNotices.openedAt)
        #expect(m.confirming?.openedAt == openedAt)
        service.releaseHeldAnswers()
        #expect(await eventually { m.confirming == nil })
    }
}
