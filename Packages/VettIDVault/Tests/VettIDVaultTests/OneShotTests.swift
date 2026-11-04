import Foundation
import Testing
@testable import VettIDVault

/// The timeout timer of a wait ends with the wait.
@Suite struct OneShotTests {
    func timersEnd(_ s: OneShot<Int>) async throws -> Bool {
        for _ in 0..<200 where s.liveTimerCount != 0 { try await Task.sleep(for: .milliseconds(10)) }
        return s.liveTimerCount == 0
    }

    @Test func aWaitCompletedEarlyLeavesNoTimerRunning() async throws {
        let s = OneShot<Int>()
        let waiting = Task { await s.wait(timeout: 3600) }
        for _ in 0..<200 where s.liveTimerCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(s.liveTimerCount == 1, "the wait started a timer")
        s.complete(7)
        #expect(await waiting.value == 7)
        #expect(try await timersEnd(s), "the timer was cancelled with the wait")
    }

    @Test func aCancelledWaitLeavesNoTimerRunning() async throws {
        let s = OneShot<Int>()
        let waiting = Task { await s.wait(timeout: 3600) }
        for _ in 0..<200 where s.liveTimerCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        waiting.cancel()
        #expect(await waiting.value == nil)
        #expect(try await timersEnd(s))
    }

    @Test func aWaitThatTimesOutReturnsNilAndLeavesNoTimer() async throws {
        let s = OneShot<Int>()
        #expect(await s.wait(timeout: 0.05) == nil)
        #expect(try await timersEnd(s))
    }

    @Test func anAbortedWaitLeavesNoTimerRunning() async throws {
        let s = OneShot<Int>()
        let waiting = Task { await s.wait(timeout: 3600) }
        for _ in 0..<200 where s.liveTimerCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        s.abort()
        #expect(await waiting.value == nil)
        #expect(try await timersEnd(s))
    }
}
