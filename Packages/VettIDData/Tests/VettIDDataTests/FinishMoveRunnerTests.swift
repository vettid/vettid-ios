import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// "Finish the move" completes once asked for: the screen that asked may go away, and the unlock still lands, opened or
/// failed. Mirrors vettid-android `FinishMoveRunnerTest`, test for test.
@MainActor
@Suite struct FinishMoveRunnerTests {
    /// The vault manager's side, as the fixture of vettid-android's test: every lock and every wipe bumps `generation`; a
    /// wipe ends with a fresh record.
    @MainActor
    final class Fixture {
        let clock = VirtualTime()
        let answer = TestDeferred<UnlockAttempt>()
        var locked = 0
        var unlocks = 0
        var outcomes: [UnlockAttempt] = []
        var generation = 0
        var signedOut = false
        var rotateOffered = false
        var takens: [Int?] = []
        var runner: FinishMoveRunner!

        init(unlock: (@MainActor (Fixture) async throws -> UnlockAttempt)? = nil) {
            runner = FinishMoveRunner(
                hold: .seconds(90), sleep: clock.sleep,
                lock: { [unowned self] in
                    locked += 1
                    generation += 1
                },
                unlock: { [unowned self] _, taken in
                    unlocks += 1
                    takens.append(taken)
                    if let unlock { return try await unlock(self) }
                    return try await answer.value()
                },
                generation: { [unowned self] in generation },
                signedOut: { [unowned self] in signedOut },
                onOutcome: { [unowned self] in outcomes.append($0) },
                onOpened: { [unowned self] _ in rotateOffered = true }
            )
        }

        /// [signedOut] false: the phone was set up again at once; only the generation tells.
        func wipe(signedOut: Bool = true) {
            generation += 1
            rotateOffered = false
            self.signedOut = signedOut
        }
    }

    func start(_ f: Fixture, _ pin: String = "975310", taken: Int? = nil) -> Task<UnlockAttempt, any Error> {
        Task { @MainActor in try await f.runner.run(pin: pin, taken: taken) }
    }

    @Test func aScreenThatGoesAwayStillGetsTheVaultOpened() async throws {
        let f = Fixture()
        let caller = start(f)
        await f.clock.runCurrent()
        #expect(f.locked == 1 && f.runner.finishing)
        // The hold's bound ends, the screen goes: the move goes on.
        await f.clock.advance(ms: 90_001)
        #expect(!f.runner.finishing)
        caller.cancel()
        f.answer.complete(.success)
        await f.clock.runCurrent()
        #expect(f.outcomes == [.success] && f.runner.failure == nil && f.rotateOffered)
    }

    @Test func aFailureIsShownEvenWhenTheScreenWentAway() async {
        let f = Fixture()
        let caller = start(f)
        await f.clock.runCurrent()
        caller.cancel()
        f.answer.complete(.failed(.transferIncomplete, code: "transfer_incomplete"))
        await f.clock.runCurrent()
        #expect(f.runner.failure == .transferIncomplete && !f.runner.finishing && !f.rotateOffered)
    }

    @Test func aWrongPinAndABackoffAreTheFailuresOfTheUnlockScreen() async throws {
        let f = Fixture()
        f.answer.complete(.badPin(retryAfterSeconds: 0))
        #expect(try await f.runner.run(pin: "111111") == .badPin(retryAfterSeconds: 0))
        #expect(f.runner.failure == .badPin)
        f.runner.clearFailure()
        #expect(f.runner.failure == nil)
    }

    @Test func aVaultFailureIsRecordedAndThrown() async {
        let f = Fixture { _ in throw VaultFailure(.network) }
        do {
            _ = try await f.runner.run(pin: "975310")
            Issue.record("no error")
        } catch let e as VaultFailure {
            #expect(e.kind == .network)
        } catch {
            Issue.record("\(error)")
        }
        #expect(f.runner.failure == .network && !f.runner.finishing)
    }

    @Test func anyOtherErrorIsRecordedAsOther() async {
        struct Odd: Error {}
        let f = Fixture { _ in throw Odd() }
        _ = try? await f.runner.run(pin: "975310")
        #expect(f.runner.failure == .other)
    }

    @Test func aSuccessOffersTheRotation() async throws {
        let f = Fixture()
        f.answer.complete(.success)
        _ = try await f.runner.run(pin: "975310")
        #expect(f.rotateOffered)
    }

    @Test func aSuccessThatAWipeOvertookOffersNothing() async throws {
        let f = Fixture()
        let caller = start(f)
        await f.clock.runCurrent()
        // `unknown_device` or `device.unlinked` while the unlock is on its way: wiped, then the unlock answers.
        f.wipe()
        f.answer.complete(.success)
        _ = try await caller.value
        #expect(f.outcomes == [.success] && !f.rotateOffered)
    }

    @Test func aSecondRunJoinsTheOneOnItsWay() async throws {
        let f = Fixture()
        let first = start(f, "975310")
        await f.clock.runCurrent()
        let second = start(f, "111111")
        await f.clock.runCurrent()
        // One lock, one unlock, one hold: the second caller started nothing.
        #expect(f.locked == 1 && f.unlocks == 1 && f.runner.finishing)
        f.answer.complete(.success)
        #expect(try await first.value == .success && second.isCancelled == false)
        #expect(try await second.value == .success)
        #expect(f.outcomes.count == 1 && !f.runner.finishing)
        // Once it has ended, the next run is a run of its own.
        _ = try await f.runner.run(pin: "975310")
        #expect(f.locked == 2 && f.outcomes.count == 2)
    }

    /// A run that release() let go of (a wipe, a deletion) is not joined: the next "Finish the move" is a run of its own, and
    /// the old one, ending later, leaves the new one's hold alone.
    @Test func aReleasedRunIsNotJoined() async throws {
        let f = Fixture()
        let stale = start(f, "975310")
        await f.clock.runCurrent()
        f.runner.release()
        #expect(!f.runner.finishing)
        let next = start(f, "111111")
        await f.clock.runCurrent()
        #expect(f.locked == 2 && f.unlocks == 2 && f.runner.finishing, "a run of its own, held")
        f.answer.complete(.success)
        _ = try await stale.value
        _ = try await next.value
        #expect(!f.runner.finishing && f.runner.failure == nil)
    }

    @Test func aLockThatOvertookTheUnlockOffersNothing() async throws {
        let f = Fixture()
        let caller = start(f)
        await f.clock.runCurrent()
        f.generation += 1 // the member locks while the unlock is on its way; the phone is not signed out
        f.answer.complete(.success)
        _ = try await caller.value
        #expect(!f.signedOut && !f.rotateOffered)
    }

    @Test func aForgottenVaultMeanwhileGetsNoOffer() async throws {
        let f = Fixture()
        let caller = start(f)
        await f.clock.runCurrent()
        f.signedOut = true // forgotten: the generation is not moved by it, only the signed-out check tells
        f.answer.complete(.success)
        _ = try await caller.value
        #expect(!f.rotateOffered)
    }

    @Test func aWipeThenANewEnrolmentGetsNoOffer() async throws {
        let f = Fixture()
        let caller = start(f)
        await f.clock.runCurrent()
        f.wipe(signedOut: false) // set up again before the unlock answers: only the generation guards
        f.answer.complete(.success)
        _ = try await caller.value
        #expect(!f.rotateOffered)
    }

    @Test func aRunAfterOneThatThrewRuns() async throws {
        let f = Fixture { f in
            if f.unlocks == 1 { throw VaultFailure(.network) }
            return .success
        }
        await #expect(throws: VaultFailure.self) { _ = try await f.runner.run(pin: "975310") }
        #expect(try await f.runner.run(pin: "975310") == .success)
        #expect(f.unlocks == 2 && f.runner.failure == nil)
    }

    @Test func aRunAfterOneThatWasCancelledRuns() async throws {
        let f = Fixture { f in
            if f.unlocks == 1 { throw CancellationError() }
            return .success
        }
        await #expect(throws: CancellationError.self) { _ = try await f.runner.run(pin: "975310") }
        #expect(try await f.runner.run(pin: "975310") == .success)
        #expect(f.unlocks == 2 && !f.runner.finishing && f.runner.failure == nil)
    }

    /// (VAULT-MESSAGING §11.14.9 step 2; chosen) The PIN's generation goes to the unlock as the screen took it.
    @Test func theGenerationTheScreenTookGoesToTheUnlock() async throws {
        let f = Fixture()
        f.answer.complete(.success)
        _ = try await f.runner.run(pin: "975310", taken: 5)
        #expect(f.takens == [5])
    }
}
