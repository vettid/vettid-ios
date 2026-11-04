import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The app's read of the phase: the launch, the foreground and protected data read only a start that could not read it; the
/// member's "Try again" (the start screen's too) is always answered.
@MainActor
@Suite struct PhaseReaderTests {
    final class Phase { var value = AppPhase.starting; var reads = 0 }

    func reader(_ phase: Phase, gate: TestDeferred<Void>? = nil) -> PhaseReader {
        PhaseReader(phase: { phase.value }, refresh: {
            phase.reads += 1
            try? await gate?.value()
        })
    }

    @Test func theLaunchReadsOnlyWhileTheStartCouldNotBeRead() async {
        let phase = Phase()
        let r = reader(phase)
        await r.ask()
        #expect(phase.reads == 1)
        phase.value = .locked
        await r.ask()
        #expect(phase.reads == 1, "a known phase is not read again by the foreground")
    }

    /// The start screen's "Try again" is the member's: it reads whatever phase the first read ended on.
    @Test func theStartScreensTryAgainIsAlwaysAnswered() async {
        let phase = Phase()
        phase.value = .locked
        let r = reader(phase)
        await r.tryAgain()
        #expect(phase.reads == 1)
    }

    /// The extra read for an ask made during a read happens only while the phase is still unread, and for the member always.
    @Test func theExtraReadFollowsTheAsker() async {
        let gate = TestDeferred<Void>()
        let phase = Phase()
        let r = reader(phase, gate: gate)
        let first = Task { await r.ask() }
        await Task.yield()
        let foreground = Task { await r.ask() }
        await Task.yield()
        phase.value = .locked // the first read ended on a known phase
        gate.complete(())
        await first.value
        await foreground.value
        #expect(phase.reads == 1, "a cold start whose first read ended on a locked vault is not read again")
        // A member's Try again during a read: answered with one more read, whatever the phase.
        let gate2 = TestDeferred<Void>()
        let r2 = reader(phase, gate: gate2)
        phase.reads = 0
        let again = Task { await r2.tryAgain() }
        await Task.yield()
        let member = Task { await r2.tryAgain() }
        await Task.yield()
        gate2.complete(())
        await again.value
        await member.value
        #expect(phase.reads == 2)
    }
}
