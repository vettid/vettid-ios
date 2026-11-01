import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

private let conn = VoteFixture.conn
private let pid = VoteFixture.pid
private let key = VoteFixture.key

private func obj(_ s: String) -> JsonObject { voteObj(s) }

/// The cast and the credential's unlock window (IOS-PLAN §4.16, ANDROID-PLAN 0.1.108 "Votes"; VAULT-MESSAGING 0.81.3
/// §10.19.8, §3.5.3): the window opened only when needed and locked after, never holding back the ballot's answer.
/// Mirrors the cast part of vettid-android `VotesManagerTest`.
@MainActor
struct VotesCastTests: VotesTestCase {
    let clock = TestClock(1_793_534_400_000)

    @Test func aCastOpensTheWindowOnlyWhenItIsClosedAndClosesWhatItOpened() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let window = TestWindow()
        let m = manager(ops, window: window)
        try await m.refresh()
        #expect(try await m.cast(key, choiceID: "yes", password: "secret") == .sending)
        #expect(window.opened == ["secret"])
        await m.windowLock?.value
        #expect(window.closed == 1)
        #expect(ops.calls.contains("cast:\(conn)/\(pid):yes"))
        // Sent once.
        #expect(ops.calls.filter { $0.hasPrefix("cast") }.count == 1)

        // A window that is already open is used and left as it was; the password is not used.
        window.until = clock.date.addingTimeInterval(120)
        #expect(m.windowOpen())
        _ = try await m.cast(key, choiceID: "no", password: "unused")
        #expect(window.opened.count == 1)
        await m.windowLock?.value
        #expect(window.closed == 1)
    }

    @Test func aCastWithAClosedWindowAndNoPasswordIsRefusedByTheVaultAndSaysSo() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        ops.refuse["cast:\(conn)/\(pid):yes"] = "credential_locked"
        let m = manager(ops)
        try await m.refresh()
        #expect(await failure { try await m.cast(key, choiceID: "yes", password: nil) }?.kind == .credentialLocked)
        // Never tried again after the refusal.
        #expect(ops.calls.filter { $0.hasPrefix("cast") }.count == 1)
    }

    @Test func noCastWhileARestoreWaitsForConfirmation() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary(extra: #","confirm_pending":true"#))
        let window = TestWindow()
        let m = manager(ops, window: window)
        try await m.refresh()
        #expect(await failure { try await m.cast(key, choiceID: "yes", password: "pw") }?.code == "checking")
        // Nothing was sent, and no window was opened for it.
        #expect(!ops.calls.contains { $0.hasPrefix("cast") })
        #expect(window.opened.isEmpty)
    }

    @Test func aWindowThePromptOpenedIsClosedEvenWhenTheCastFails() async {
        let ops = FakeVoteOps()
        ops.refuse["cast:\(conn)/\(pid):yes"] = "not_open"
        let window = TestWindow()
        let m = manager(ops, window: window)
        #expect(await failure { try await m.cast(key, choiceID: "yes", password: "pw") }?.code == "not_open")
        await m.windowLock?.value
        #expect(window.closed == 1)
    }

    @Test func aCancelledCastStillLocksTheWindowItOpened() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let gate = TestDeferred<Void>()
        ops.castGate = gate
        let window = TestWindow()
        let m = manager(ops, window: window)
        try await m.refresh()
        let job = Task { try await m.cast(key, choiceID: "yes", password: "pw") }
        #expect(await eventually { !window.opened.isEmpty })
        job.cancel()
        _ = await job.result
        // The lock ran to its end although its caller was cancelled (a screen that left).
        await m.windowLock?.value
        #expect(window.closed == 1)
        #expect(m.windowNotClosed == nil)
    }

    @Test func anUnlockWhoseAnswerWasLostIsStillLocked() async {
        let ops = FakeVoteOps()
        let window = TestWindow()
        window.openFail = VaultFailure(.noResponse)
        let m = manager(ops, window: window)
        #expect(await failure { try await m.cast(key, choiceID: "yes", password: "pw") }?.kind == .noResponse)
        await m.windowLock?.value
        #expect(window.closed == 1)
        #expect(!ops.calls.contains { $0.hasPrefix("cast") })
    }

    @Test func anUnlockThatFailsInAnyWayButARefusalIsStillLocked() async {
        for f in [VaultFailure(.other, code: "unreadable_result"), VaultFailure(.network)] {
            let window = TestWindow()
            window.openFail = f
            let m = manager(FakeVoteOps(), window: window)
            _ = await failure { try await m.cast(key, choiceID: "yes", password: "pw") }
            await m.windowLock?.value
            #expect(window.closed == 1, "\(f.kind)")
        }
        // Only a definite refusal opened nothing.
        for kind: FailureKind in [.badPassword, .backoff, .credentialFrozen, .rotationRequired, .ownerCheckRequired, .credentialUnsettled] {
            let window = TestWindow()
            window.openFail = VaultFailure(kind)
            let m = manager(FakeVoteOps(), window: window)
            #expect(await failure { try await m.cast(key, choiceID: "yes", password: "pw") }?.kind == kind)
            await m.windowLock?.value
            #expect(window.closed == 0, "\(kind)")
        }
    }

    @Test func aLockThatFailedIsToldNotSwallowed() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let window = TestWindow()
        window.closeFail = VaultFailure(.noResponse)
        let m = manager(ops, window: window)
        try await m.refresh()
        _ = try await m.cast(key, choiceID: "yes", password: "pw")
        // The notice knows how long the window stays open unused.
        await m.windowLock?.value
        #expect(m.windowNotClosed == WindowNotClosed(ttlSeconds: 300))
        // Close it now: the notice stays while the lock fails, and goes only when it went through.
        #expect(await failure { try await m.closeWindowNow() } != nil)
        #expect(m.windowNotClosed == WindowNotClosed(ttlSeconds: 300))
        window.closeFail = nil
        try await m.closeWindowNow()
        #expect(m.windowNotClosed == nil)
    }

    @Test func theBallotIsAnsweredBeforeTheLockOfTheWindowEnds() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let window = TestWindow()
        let lockGate = TestDeferred<Void>()
        let c = clock
        let m = VotesManager(
            ops: { ops }, windowUntil: { window.until },
            openWindow: { _ in window.until = c.date.addingTimeInterval(300) },
            closeWindow: {
                try await lockGate.value()
                window.closed += 1
            },
            now: { c.date }
        )
        try await m.refresh()
        // A slow lock (a bad network) does not hold back the recorded vote.
        #expect(try await m.cast(key, choiceID: "yes", password: "pw") == .sending)
        #expect(window.closed == 0)
        lockGate.complete(())
        await m.windowLock?.value
        #expect(window.closed == 1)
        #expect(m.windowNotClosed == nil)
    }

    @Test func aCastWithNoAnswerIsNotSentAgainAndTheWindowItOpenedIsLocked() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let window = TestWindow()
        let m = VotesManager(
            ops: { NoAnswerCast(inner: ops) },
            windowUntil: { window.until },
            openWindow: { password in
                window.opened.append(password)
                window.until = Date().addingTimeInterval(300)
            },
            closeWindow: { window.closed += 1 }
        )
        try await m.refresh()
        #expect(await failure { try await m.cast(key, choiceID: "yes", password: "pw") }?.kind == .noResponse)
        await m.windowLock?.value
        #expect(window.closed == 1)
        #expect(ops.calls.filter { $0.hasPrefix("cast") }.count == 1)
    }

    @Test func aLockThatFailsAfterTheVaultLockedTellsNothing() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let window = TestWindow()
        let gate = TestDeferred<Void>()
        let m = gatedWindow(window, ops, gate: gate, fails: true)
        try await m.refresh()
        _ = try await m.cast(key, choiceID: "yes", password: "pw")
        // The vault locked meanwhile: the manager is cleared and the vault manager forgets the window.
        m.clear()
        window.until = nil
        gate.complete(())
        await m.windowLock?.value
        #expect(window.closed == 1)
        #expect(m.windowNotClosed == nil)
    }

    @Test func aLockThatFailsAfterTheWindowClosedOtherwiseTellsNothing() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let window = TestWindow()
        let gate = TestDeferred<Void>()
        let m = gatedWindow(window, ops, gate: gate, fails: true)
        try await m.refresh()
        _ = try await m.cast(key, choiceID: "yes", password: "pw")
        window.until = nil // locked from elsewhere (the settings' Lock now, the window's end)
        gate.complete(())
        await m.windowLock?.value
        #expect(m.windowNotClosed == nil)
    }

    @Test func aSecondCastWhileTheFirstsLockIsOnItsWayOpensItsOwnWindow() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary(), summary(conn: "conn-2"))
        let window = TestWindow()
        let gate = TestDeferred<Void>()
        let m = gatedWindow(window, ops, gate: gate, fails: false)
        try await m.refresh()
        _ = try await m.cast(key, choiceID: "yes", password: "pw1")
        // The window is about to close: a screen asks for the password again.
        #expect(!m.windowOpen())
        let second = Task { try await m.cast(VoteKey(connectionID: "conn-2", proposalID: pid), choiceID: "no", password: "pw2") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!ops.calls.contains("cast:conn-2/\(pid):no"), "waits for the first lock")
        gate.complete(())
        #expect(try await second.value == .sending)
        await m.windowLock?.value
        #expect(window.opened == ["pw1", "pw2"])
        #expect(window.closed == 2)
        #expect(m.windowNotClosed == nil)
    }
}
