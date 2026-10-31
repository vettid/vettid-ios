import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

private let pid = VoteFixture.pid
private let key = VoteFixture.key

/// A fake of the system's background time: what began and ended, in order, and the expirations to fire.
@MainActor
final class FakeBackgroundTasks: BackgroundTasks {
    nonisolated init() {}

    var log: [String] = []
    var begun = 0
    var ended: [Int] = []
    var expirations: [Int: @MainActor () -> Void] = [:]
    /// The system takes the time back inside `begin`, before it returns.
    var expireInBegin = false
    /// The system gives no task.
    var refuse = false

    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int? {
        begun += 1
        log.append("begin:\(name)")
        expirations[begun] = expiration
        if refuse { return nil }
        if expireInBegin { expiration() }
        return begun
    }

    /// Waits until [condition] holds, at most 5 s.
    func wait(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func end(_ token: Int) {
        ended.append(token)
        log.append("end:\(token)")
    }
}

/// The lock of a cast's window runs inside a background task (IOS-PLAN §6.6).
@MainActor
struct VotesBackgroundTests: VotesTestCase {
    let clock = TestClock(1_793_534_400_000)

    private func make(
        _ tasks: FakeBackgroundTasks, _ window: TestWindow, _ ops: FakeVoteOps, gate: TestDeferred<Void>? = nil, fails: Bool = false
    ) -> VotesManager {
        let c = clock
        return VotesManager(
            ops: { ops }, windowUntil: { window.until },
            openWindow: { password in
                window.opened.append(password)
                window.until = c.date.addingTimeInterval(300)
            },
            closeWindow: {
                tasks.log.append("close")
                try await gate?.value()
                window.closed += 1
                if fails { throw VaultFailure(.noResponse) }
                window.until = nil
            },
            unlockTtl: { 300 },
            now: { c.date },
            backgroundTasks: tasks
        )
    }

    private func ops() -> FakeVoteOps {
        let o = FakeVoteOps()
        o.list = listing(summary(), summary(conn: "conn-2"))
        return o
    }

    @Test func theTaskBeginsBeforeTheLockRequestAndEndsAfterASuccess() async throws {
        let tasks = FakeBackgroundTasks()
        let m = make(tasks, TestWindow(), ops())
        try await m.refresh()
        _ = try await m.cast(key, choiceID: "yes", password: "pw")
        await m.windowLock?.value
        #expect(tasks.log == ["begin:vote-window-lock", "close", "end:1"])
    }

    @Test func aCastThatOpenedNothingAsksForNoTime() async throws {
        let tasks = FakeBackgroundTasks()
        let window = TestWindow()
        window.until = clock.date.addingTimeInterval(300)
        let m = make(tasks, window, ops())
        try await m.refresh()
        _ = try await m.cast(key, choiceID: "yes", password: nil)
        await m.windowLock?.value
        #expect(tasks.log.isEmpty)
    }

    @Test func theTaskEndsAfterAFailureThatLeavesTheWindowNotClosed() async throws {
        let tasks = FakeBackgroundTasks()
        let m = make(tasks, TestWindow(), ops(), fails: true)
        try await m.refresh()
        _ = try await m.cast(key, choiceID: "yes", password: "pw")
        await m.windowLock?.value
        #expect(m.windowNotClosed == WindowNotClosed(ttlSeconds: 300))
        #expect(tasks.log == ["begin:vote-window-lock", "close", "end:1"])
    }

    @Test func theExpirationEndsTheTaskLeavesTheNoticeAndNothingEndsItTwice() async throws {
        let tasks = FakeBackgroundTasks()
        let gate = TestDeferred<Void>()
        let window = TestWindow()
        let m = make(tasks, window, ops(), gate: gate, fails: true)
        try await m.refresh()
        _ = try await m.cast(key, choiceID: "yes", password: "pw")
        await tasks.wait { tasks.log.contains("close") }
        #expect(tasks.ended.isEmpty)
        tasks.expirations[1]?()
        #expect(tasks.ended == [1])
        // The request goes on and fails later: the notice shows, the task is not ended again.
        gate.complete(())
        await m.windowLock?.value
        #expect(m.windowNotClosed == WindowNotClosed(ttlSeconds: 300))
        #expect(tasks.ended == [1])
        tasks.expirations[1]?()
        #expect(tasks.ended == [1])
    }

    @Test func theExpirationLeavesAnEarlierNoticeSet() async throws {
        let tasks = FakeBackgroundTasks()
        let gate = TestDeferred<Void>()
        let window = TestWindow()
        let m = make(tasks, window, ops(), gate: gate, fails: true)
        try await m.refresh()
        _ = try await m.cast(key, choiceID: "yes", password: "pw")
        gate.complete(())
        await m.windowLock?.value
        #expect(m.windowNotClosed != nil)
        tasks.expirations[1]?()
        #expect(m.windowNotClosed == WindowNotClosed(ttlSeconds: 300))
        #expect(tasks.ended == [1])
    }

    @Test func aSecondCastThatWaitsForTheFirstsLockLeaksNoTask() async throws {
        let tasks = FakeBackgroundTasks()
        let gate = TestDeferred<Void>()
        let window = TestWindow()
        let m = make(tasks, window, ops(), gate: gate)
        try await m.refresh()
        _ = try await m.cast(key, choiceID: "yes", password: "pw1")
        let second = Task { try await m.cast(VoteKey(connectionID: "conn-2", proposalID: pid), choiceID: "no", password: "pw2") }
        await tasks.wait { tasks.log.contains("close") }
        #expect(tasks.begun == 1 && tasks.ended.isEmpty)
        gate.complete(())
        _ = try await second.value
        await m.windowLock?.value
        #expect(tasks.begun == 2)
        #expect(tasks.ended.sorted() == [1, 2])
    }

    @Test func aCastThatFailsAfterTheUnlockStillBalancesBeginAndEnd() async throws {
        let tasks = FakeBackgroundTasks()
        let o = ops()
        o.refuse["cast:conn-1/\(pid):yes"] = "not_open"
        let m = make(tasks, TestWindow(), o)
        try await m.refresh()
        _ = await failure { try await m.cast(key, choiceID: "yes", password: "pw") }
        await m.windowLock?.value
        #expect(tasks.begun == 1)
        #expect(tasks.ended == [1])
    }

    @Test func anExpirationInsideBeginEndsTheTokenOnceAndTheLockStillRuns() async throws {
        let tasks = FakeBackgroundTasks()
        tasks.expireInBegin = true
        let window = TestWindow()
        let m = make(tasks, window, ops())
        try await m.refresh()
        _ = try await m.cast(key, choiceID: "yes", password: "pw")
        await m.windowLock?.value
        #expect(tasks.ended == [1])
        #expect(window.closed == 1)
        #expect(m.windowNotClosed == nil)
    }

    @Test func noTaskFromTheSystemEndsNothingAndTheLockStillRuns() async throws {
        let tasks = FakeBackgroundTasks()
        tasks.refuse = true
        let window = TestWindow()
        let m = make(tasks, window, ops(), fails: true)
        try await m.refresh()
        _ = try await m.cast(key, choiceID: "yes", password: "pw")
        await m.windowLock?.value
        #expect(tasks.ended.isEmpty)
        #expect(window.closed == 1)
        #expect(m.windowNotClosed == WindowNotClosed(ttlSeconds: 300))
    }
}
