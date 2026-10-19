import Foundation
import Testing
@testable import VettIDData

/// The one-step release update (owner decision 2026-10-09): lock → unlock with the approval → moved → unlock again.
/// Mirrors vettid-android `ReleaseUpdateManagerTest`.
@MainActor
@Suite struct ReleaseUpdateManagerTests {
    static func rel(_ n: UInt64, _ status: String = "active") -> ReleaseView {
        ReleaseView(
            number: n, pcr0: String(repeating: String(format: "%02d", n), count: 48), status: status, endsAt: nil,
            notes: "https://vettid.org/r/\(n)"
        )
    }

    let offer = ReleaseUpdateOffer(current: rel(4, "deprecated"), target: rel(5))

    /// One unlock as the ops saw it.
    struct Call: Equatable {
        let pin: String
        let approve: UInt64?
        let abandon: Bool
    }

    @MainActor
    final class Ops: ReleaseUpdateOps {
        var log: [String] = []
        var unlocks: [Call] = []
        var results: [UpdateStepResult] = []
        var offerValue: ReleaseUpdateOffer?
        var offerFailures = 0
        var due = false
        var lockFails: VaultFailure?
        var abandonable = true
        var release: UInt64 = 4
        var hold: FailureKind?
        /// Unlocks that report `release_starting` through the API client's callback before answering.
        var startingCallbacks = 0
        /// Runs right after such a report, while the unlock still waits.
        var whileStarting: () -> Void = {}

        func offer() async throws -> ReleaseUpdateOffer? {
            if offerFailures > 0 {
                offerFailures -= 1
                throw VaultFailure(.network)
            }
            return offerValue
        }

        func ownerCheckDue() -> Bool { due }

        func lock() async throws {
            log.append("lock")
            if let lockFails { throw lockFails }
        }

        func unlock(
            pin: String, approve: ReleaseView?, abandon: Bool, afterMove: Bool, onStarting: @escaping @MainActor () -> Void
        ) async -> UpdateStepResult {
            log.append(afterMove ? "unlock-after-move" : "unlock")
            unlocks.append(Call(pin: pin, approve: approve?.number, abandon: abandon))
            if startingCallbacks > 0 {
                startingCallbacks -= 1
                onStarting()
                whileStarting()
            }
            return results.isEmpty ? .opened : results.removeFirst()
        }

        func canAbandon() -> Bool { abandonable }

        func releaseNumber() -> UInt64 { release }

        func changeHold() -> FailureKind? { hold }
    }

    /// The waits while a release starts, recorded; none is waited for.
    final class Sleeps: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: [Int64] = []
        var all: [Int64] { lock.withLock { seconds } }
        func sleep(_ d: Duration) { lock.withLock { seconds.append(d.components.seconds) } }
    }

    func manager(_ ops: Ops, _ sleeps: Sleeps = Sleeps()) -> ReleaseUpdateManager {
        ReleaseUpdateManager(ops: ops) { sleeps.sleep($0) }
    }

    @Test func lockThenApproveThenMovedThenReopenWithTheSamePin() async throws {
        let ops = Ops()
        ops.results = [.moved, .opened]
        let m = manager(ops)
        #expect(m.start(pin: "246802", offer: offer))
        await m.settle()
        #expect(ops.log == ["lock", "unlock", "unlock-after-move"])
        #expect(ops.unlocks == [Call(pin: "246802", approve: 5, abandon: false), Call(pin: "246802", approve: nil, abandon: false)])
        let p = try #require(m.progress)
        #expect(p.step == .done && p.vaultOpen)
        #expect(m.offer == nil)
        m.finish()
        #expect(m.progress == nil)
    }

    @Test func theApprovalIsSentOnlyOnceAndOnlyForTheOfferedRelease() async {
        let ops = Ops()
        // Routed to the old release again: it reports the move once more.
        ops.results = [.moved, .moved, .opened]
        let m = manager(ops)
        _ = m.start(pin: "246802", offer: offer)
        await m.settle()
        #expect(ops.unlocks.filter { $0.approve != nil }.count == 1)
        #expect(ops.unlocks.first?.approve == 5)
        #expect(m.progress?.step == .done)
    }

    @Test func nothingTouchesTheVaultWithoutStart() async {
        let ops = Ops()
        ops.offerValue = offer
        let m = manager(ops)
        await m.refreshOffer()
        m.retry(pin: "246802")
        m.abandon(pin: "246802")
        m.finish()
        await m.settle()
        #expect(m.offer == offer)
        #expect(ops.log.isEmpty)
    }

    @Test func theOwnerCheckComesFirst() async {
        let ops = Ops()
        ops.due = true
        let m = manager(ops)
        #expect(!m.start(pin: "246802", offer: offer))
        await m.settle()
        #expect(m.progress == nil && ops.log.isEmpty)
    }

    @Test func releaseStartingIsWaitedForAndTriedAgain() async {
        let ops = Ops()
        let starting = UpdateStepResult.failed(.vaultUnavailable, code: ReleaseUpdateManager.codeReleaseStarting, retryAfterSeconds: 30)
        ops.results = [.moved, starting, starting, .opened]
        let sleeps = Sleeps()
        let m = manager(ops, sleeps)
        _ = m.start(pin: "246802", offer: offer)
        await m.settle()
        #expect(sleeps.all == [30, 30])
        #expect(m.progress?.step == .done)
        #expect(m.progress?.starting == false)
        #expect(ops.unlocks.count == 4)
    }

    @Test func startingReportedByTheApiClientShowsWhileItWaits() async {
        let ops = Ops()
        ops.startingCallbacks = 1
        ops.results = [.moved]
        let m = manager(ops)
        var seen: UpdateProgress?
        ops.whileStarting = { seen = m.progress }
        _ = m.start(pin: "246802", offer: offer)
        await m.settle()
        #expect(seen?.starting == true)
        #expect(seen?.step == .approving)
        #expect(m.progress?.step == .done)
        #expect(m.progress?.starting == false)
    }

    @Test func aReleaseThatNeverStartsIsAFailureNotAnEndlessWait() async {
        let ops = Ops()
        let starting = UpdateStepResult.failed(.vaultUnavailable, code: ReleaseUpdateManager.codeReleaseStarting, retryAfterSeconds: 10)
        ops.results = [.moved] + Array(repeating: starting, count: ReleaseUpdateManager.maxStartRetries + 1)
        let sleeps = Sleeps()
        let m = manager(ops, sleeps)
        _ = m.start(pin: "246802", offer: offer)
        await m.settle()
        #expect(sleeps.all.count == ReleaseUpdateManager.maxStartRetries)
        #expect(m.progress?.step == .newReleaseFailed)
        #expect(m.progress?.failureCode == ReleaseUpdateManager.codeReleaseStarting)
        #expect(m.progress?.canAbandon == true)
    }

    @Test func eachRefusalLeavesTheVaultOpenOnItsRelease() async throws {
        for code in ["target", "downgrade", "approval", "seal_key", "pending", "write"] {
            let ops = Ops()
            ops.results = [.refused(code)]
            let m = manager(ops)
            _ = m.start(pin: "246802", offer: offer)
            await m.settle()
            let p = try #require(m.progress)
            #expect(p.step == .refused, "\(code)")
            #expect(p.refusal == code)
            #expect(p.vaultOpen)
            // The refusing unlock opened the vault; nothing more is sent.
            #expect(ops.log == ["lock", "unlock"])
            #expect(ReleaseUpdateOffer(current: p.from, target: p.to) == offer)
        }
    }

    @Test func aWrongPinLeavesTheVaultLockedAndTheNextPinApprovesAgain() async {
        let ops = Ops()
        ops.results = [.badPin(retryAfterSeconds: 0), .moved, .opened]
        let m = manager(ops)
        _ = m.start(pin: "111111", offer: offer)
        await m.settle()
        #expect(m.progress?.step == .badPin)
        #expect(m.progress?.failure == .badPin)
        #expect(m.progress?.vaultOpen == false)
        m.retry(pin: "246802")
        await m.settle()
        #expect(m.progress?.step == .done)
        #expect(ops.unlocks == [
            Call(pin: "111111", approve: 5, abandon: false), Call(pin: "246802", approve: 5, abandon: false),
            Call(pin: "246802", approve: nil, abandon: false),
        ])
        // Locked once only: the wrong PIN left it locked.
        #expect(ops.log.filter { $0 == "lock" }.count == 1)
    }

    @Test func theEnclaveBackoffIsReported() async {
        let ops = Ops()
        ops.results = [.backoff(retryAfterSeconds: 90)]
        let m = manager(ops)
        _ = m.start(pin: "111111", offer: offer)
        await m.settle()
        #expect(m.progress?.step == .badPin)
        #expect(m.progress?.failure == .backoff)
        #expect(m.progress?.waitSeconds == 90)
    }

    @Test func aLockThatFailsChangesNothing() async throws {
        let ops = Ops()
        ops.lockFails = VaultFailure(.network)
        let m = manager(ops)
        _ = m.start(pin: "246802", offer: offer)
        await m.settle()
        let p = try #require(m.progress)
        #expect(p.step == .failed && p.vaultOpen)
        #expect(ops.unlocks.isEmpty)
        m.finish()
        #expect(ReleaseUpdateOffer(current: p.from, target: p.to) == offer)
    }

    @Test func aFailureBeforeTheMoveIsTriedAgainWithTheApproval() async {
        let ops = Ops()
        ops.results = [.failed(.network, code: nil), .moved, .opened]
        let m = manager(ops)
        _ = m.start(pin: "246802", offer: offer)
        await m.settle()
        #expect(m.progress?.step == .failed)
        #expect(m.progress?.vaultOpen == false)
        m.retry(pin: "246802")
        await m.settle()
        #expect(m.progress?.step == .done)
        #expect(ops.unlocks.map(\.approve) == [5, 5, nil])
    }

    /// (iPhone) The approved unlock's answer was lost after the vault moved: the approval sent again reaches the new
    /// release, which confirms the move and says nothing of the update. The update is done, not "not moved".
    @Test func anApprovalWhoseAnswerWasLostIsDoneOnceTheNewReleaseOpens() async {
        let ops = Ops()
        ops.results = [.failed(.noResponse, code: nil), .opened]
        let m = manager(ops)
        _ = m.start(pin: "246802", offer: offer)
        await m.settle()
        #expect(m.progress?.step == .failed)
        ops.release = 5
        m.retry(pin: "246802")
        await m.settle()
        #expect(m.progress?.step == .done)
        #expect(m.offer == nil)
    }

    @Test func aNewReleaseThatDoesNotOpenOffersTheWayBack() async throws {
        let ops = Ops()
        ops.results = [.moved, .failed(.noResponse, code: nil), .abandoned]
        let m = manager(ops)
        _ = m.start(pin: "246802", offer: offer)
        await m.settle()
        let p = try #require(m.progress)
        #expect(p.step == .newReleaseFailed && p.canAbandon)
        m.abandon(pin: "246802")
        await m.settle()
        #expect(m.progress?.step == .abandoned)
        #expect(m.progress?.vaultOpen == true)
        #expect(ops.unlocks.last == Call(pin: "246802", approve: nil, abandon: true))
    }

    @Test func noWayBackOnceTheMoveCannotBeAbandoned() async {
        let ops = Ops()
        ops.abandonable = false
        ops.results = [.moved, .failed(.noResponse, code: nil)]
        let m = manager(ops)
        _ = m.start(pin: "246802", offer: offer)
        await m.settle()
        #expect(m.progress?.canAbandon == false)
        m.abandon(pin: "246802")
        await m.settle()
        #expect(ops.unlocks.count == 2)
        #expect(m.progress?.step == .newReleaseFailed)
    }

    @Test func theNewReleaseIsTriedAgainWithoutAnApproval() async {
        let ops = Ops()
        ops.results = [.moved, .failed(.noResponse, code: nil), .opened]
        let m = manager(ops)
        _ = m.start(pin: "246802", offer: offer)
        await m.settle()
        m.retry(pin: "246802")
        await m.settle()
        #expect(m.progress?.step == .done)
        #expect(ops.unlocks.map(\.approve) == [5, nil, nil])
    }

    @Test func aSecondStartWhileOneRunsIsRefused() async {
        let ops = Ops()
        ops.results = [.moved]
        let m = manager(ops)
        #expect(m.start(pin: "246802", offer: offer))
        #expect(!m.start(pin: "246802", offer: offer))
        await m.settle()
        #expect(ops.log.filter { $0 == "lock" }.count == 1)
    }

    /// (§11.14.9) A PIN or password change undecided: the update neither starts, nor retries, nor returns; nothing is sent
    /// and the step says why.
    @Test func anUndecidedChangeHoldsEveryStep() async {
        let ops = Ops()
        ops.hold = .changeChecking
        let m = manager(ops)
        #expect(m.changeHold == .changeChecking)
        #expect(!m.start(pin: "246802", offer: offer))
        #expect(ops.log.isEmpty && m.progress == nil)
        ops.hold = nil
        ops.results = [.badPin(retryAfterSeconds: 0)]
        _ = m.start(pin: "111111", offer: offer)
        await m.settle()
        ops.hold = .changeUnresolved
        m.retry(pin: "246802")
        await m.settle()
        #expect(ops.unlocks.count == 1)
        #expect(m.progress?.failure == .changeUnresolved && m.progress?.failureCode == ReleaseUpdateManager.codeChangeHeld)
        ops.hold = nil
        ops.results = [.moved, .failed(.noResponse, code: nil)]
        m.retry(pin: "246802")
        await m.settle()
        #expect(m.progress?.step == .newReleaseFailed)
        ops.hold = .changeChecking
        m.abandon(pin: "246802")
        await m.settle()
        #expect(ops.unlocks.count == 3 && m.progress?.step == .newReleaseFailed)
    }

    /// The lost-answer rule only after a failure: a first approval answered without an `update` member is "not moved",
    /// whatever release this phone records.
    @Test func theLostAnswerRuleIsOnlyForARetryAfterAFailure() async {
        let ops = Ops()
        ops.release = 5
        ops.results = [.opened]
        let m = manager(ops)
        _ = m.start(pin: "246802", offer: offer)
        await m.settle()
        #expect(m.progress?.step == .refused && m.progress?.refusal == ReleaseUpdateManager.codeNotMoved)
    }

    /// The banner (owner decision 2026-10-09): shown while there is an offer, hidden 24 h after a dismissal of this
    /// release and kind, shown again for another release or kind, and when the clock was set back.
    @Test func theBannersDismissal() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!ReleaseNotices.bannerVisible(nil, nil, now: now))
        #expect(ReleaseNotices.bannerVisible(offer, nil, now: now))
        let ops = Ops()
        ops.offerValue = offer
        let m = manager(ops)
        await m.refreshOffer()
        m.dismissBanner(at: now)
        let d = m.dismissal
        #expect(!ReleaseNotices.bannerVisible(offer, d, now: now.addingTimeInterval(3600)))
        #expect(ReleaseNotices.bannerVisible(offer, d, now: now.addingTimeInterval(ReleaseNotices.dismissFor)))
        #expect(ReleaseNotices.bannerVisible(offer, d, now: now.addingTimeInterval(-60)))
        let other = ReleaseUpdateOffer(current: Self.rel(4, "deprecated"), target: Self.rel(6))
        #expect(ReleaseNotices.bannerVisible(other, d, now: now.addingTimeInterval(60)))
        let ending = ReleaseUpdateOffer(current: Self.rel(4, "retired"), target: Self.rel(5))
        #expect(ReleaseNotices.bannerVisible(ending, d, now: now.addingTimeInterval(60)))
    }

    @Test func anOpenWithoutUpdateMemberIsNotTakenForAMove() async {
        let ops = Ops()
        ops.results = [.opened]
        let m = manager(ops)
        _ = m.start(pin: "246802", offer: offer)
        await m.settle()
        #expect(m.progress?.step == .refused)
        #expect(m.progress?.refusal == ReleaseUpdateManager.codeNotMoved)
    }

    @Test func aFailedRefreshKeepsTheLastOffer() async {
        let ops = Ops()
        ops.offerValue = offer
        let m = manager(ops)
        await m.refreshOffer()
        ops.offerFailures = 1
        await m.refreshOffer()
        #expect(m.offer == offer)
    }

    @Test func theOfferIsKnownOnlyOnceRead() async {
        let ops = Ops()
        ops.offerFailures = 1
        let m = manager(ops)
        #expect(!m.offerKnown)
        // A failed read: still not known.
        await m.refreshOffer()
        #expect(!m.offerKnown)
        await m.refreshOffer()
        #expect(m.offerKnown)
        #expect(m.offer == nil)
    }

    /// The offer's kind and its rules (§11.10.1 statuses, §11.10.6).
    @Test func theOffersKindAndRules() {
        #expect(ReleaseUpdateOffer(current: Self.rel(4), target: Self.rel(5)).kind == .available)
        #expect(ReleaseUpdateOffer(current: Self.rel(4, "deprecated"), target: Self.rel(5)).kind == .available)
        var ending = Self.rel(4, "deprecated")
        ending.endsAt = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ReleaseUpdateOffer(current: ending, target: Self.rel(5)).kind == .ending)
        #expect(ReleaseUpdateOffer(current: Self.rel(4, "retired"), target: Self.rel(5)).kind == .ending)
        #expect(ReleaseUpdateOffer(current: Self.rel(4, "removed"), target: Self.rel(5)).kind == .ended)
        #expect(ReleaseUpdateOffer.of(sealed: Self.rel(5), newest: Self.rel(5)) == nil)
        #expect(ReleaseUpdateOffer.of(sealed: Self.rel(5), newest: Self.rel(4)) == nil)
        #expect(ReleaseUpdateOffer.of(sealed: Self.rel(4), newest: Self.rel(6, "deprecated")) == nil)
        #expect(ReleaseUpdateOffer.of(sealed: nil, newest: Self.rel(6)) == nil)
        let between = [Self.rel(2), Self.rel(4), Self.rel(5), Self.rel(6)]
        let o = ReleaseUpdateOffer.of(sealed: Self.rel(3), newest: Self.rel(6), between: between)
        #expect(o?.between.map(\.number) == [4, 5])
    }
}
