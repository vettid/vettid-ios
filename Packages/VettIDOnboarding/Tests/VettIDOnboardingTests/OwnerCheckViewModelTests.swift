import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The owner-check screen (VAULT-MESSAGING §3.6.5, §3.6.7). Mirrors vettid-android `OwnerCheckViewModelTest`, test for
/// test.
@MainActor
@Suite struct OwnerCheckViewModelTests {
    let vault = FakeVaultRepository(.unlocked)
    let ticker = ManualTicker()

    init() {
        vault.ownerCheck = OwnerCheckView(
            state: .held, deadline: Date().addingTimeInterval(-600), failures: 1,
            waiting: WaitingCounts(messages: 3, requests: 1, other: 2)
        )
    }

    func vm(_ mode: OwnerCheckMode = .gated) async -> OwnerCheckViewModel {
        let vm = OwnerCheckViewModel(repo: vault, vault: vault, tick: ticker.tick)
        vm.start(mode)
        await vm.settle()
        return vm
    }

    func enter(_ vm: OwnerCheckViewModel, pin: String = "975310", password: String = "pw") {
        vm.setPin(pin)
        vm.setPassword(password)
    }

    @Test func bothEntriesTogetherThenForgotten() async {
        let vm = await vm()
        #expect(vm.state.view?.waiting == WaitingCounts(messages: 3, requests: 1, other: 2))
        enter(vm, pin: "97531")
        #expect(!vm.state.submitAllowed, "a PIN is 6–32 digits")
        vm.setPin("975310")
        vm.submit()
        await vm.settle()
        #expect(vault.calls.filter { $0 == "check" } == ["check"])
        #expect(vault.lastPin == "975310" && vault.lastPassword == "pw" && vault.lastHoldOff == nil)
        #expect(vm.state.passed && vm.state.pin.isEmpty && vm.state.password.isEmpty)
    }

    @Test func wrongEntriesSayWhichAndHowManyAreLeft() async {
        vault.checkResults = [.badPin(checksLeft: 8), .badPassword(checksLeft: 7)]
        let vm = await vm()
        enter(vm, pin: "111111")
        vm.submit()
        await vm.settle()
        #expect(vm.state.message == .badPin(checksLeft: 8) && vm.state.checksLeft == 8)
        #expect(vm.state.pin.isEmpty && vm.state.password.isEmpty)
        enter(vm, password: "nope")
        vm.submit()
        await vm.settle()
        #expect(vm.state.message == .badPassword(checksLeft: 7) && !vm.state.passed)
    }

    @Test func aBackoffRunsDown() async {
        vault.checkResults = [.backoff(retryAfterSeconds: 3)]
        let vm = await vm()
        enter(vm)
        vm.submit()
        await vm.settle()
        #expect(vm.state.waitSeconds == 3 && vm.state.message == .backoff)
        enter(vm)
        #expect(!vm.state.submitAllowed)
        await ticker.advance(3, vm)
        #expect(vm.state.waitSeconds == 0)
    }

    @Test func theHoldGoesOffOnlyWithACheck() async throws {
        let vm = await vm(.holdOff)
        vm.setHoldOff(.threeDays)
        enter(vm)
        vm.submit()
        await vm.settle()
        let until = try #require(vault.lastHoldOff?.until)
        let d = until.timeIntervalSinceNow
        #expect(d > 2 * 86_400 && d <= 3 * 86_400)
        #expect(vault.ownerCheck?.hold == false)

        let forever = await self.vm(.holdOff)
        forever.setHoldOff(.untilTurnedOn)
        enter(forever)
        forever.submit()
        await forever.settle()
        #expect(vault.lastHoldOff != nil && vault.lastHoldOff?.until == nil)
    }

    @Test func theUnlockChecksAnswerIsShownOnce() async {
        vault.unlockCheckOutcome = .badPassword(checksLeft: 9)
        let vm = await vm()
        #expect(vm.state.message == .badPassword(checksLeft: 9))
        #expect(vault.unlockCheckOutcome == nil)
    }

    @Test func theLockActionLocksTheVault() async {
        let vm = await vm()
        vm.setPin("975310")
        vm.lockVault()
        await vm.settle()
        #expect(vault.phase == .locked && vm.state.pin.isEmpty)
    }

    @Test func aFailureIsShown() async {
        vault.checkResults = [.failed(.network, code: nil)]
        let vm = await vm()
        enter(vm)
        vm.submit()
        await vm.settle()
        #expect(vm.state.message == .failed(.network, code: nil))
    }

    /// Release R (§11.14.5): a check that passed without the presence recorded keeps the screen with the notice.
    @Test func aPassedCheckWithThePresenceNotRecorded() async {
        vault.presenceUnrecorded = true
        let vm = await vm(.voluntary)
        #expect(vm.state.presenceUnrecorded)
        enter(vm)
        vm.submit()
        await vm.settle()
        #expect(vm.state.passedUnrecorded && !vm.state.passed && vm.state.pin.isEmpty)
        vm.acknowledgePresence()
        #expect(vm.state.passed)
    }

    @Test func aPassedCheckWithThePresenceRecordedCloses() async {
        let vm = await vm(.voluntary)
        enter(vm)
        vm.submit()
        await vm.settle()
        #expect(vm.state.passed && !vm.state.passedUnrecorded)
    }

    /// (iPhone, IOS-PLAN §6.3) Leaving the foreground drops what was typed; a submit the model refuses keeps no PIN.
    @Test func typedSecretsAreDropped() async {
        let vm = await vm()
        enter(vm)
        vm.forgetSecrets()
        #expect(vm.state.pin.isEmpty && vm.state.password.isEmpty)
        vm.setPin("975310")
        vm.submit() // no password
        #expect(vm.state.pin.isEmpty && !vault.calls.contains("check"))
    }
}

/// The gated check's waiting card (VAULT-MESSAGING §3.6.5): shown whenever the check gates the app, also when only the
/// phone's clock has passed the deadline; counts the vault has not reported are unknown, never "nothing new". Mirrors
/// vettid-android `WaitingCardTest`.
@Suite struct WaitingCardTests {
    let now = Date(timeIntervalSince1970: 1_791_384_000)
    var ok: OwnerCheckView { OwnerCheckView(state: .ok, deadline: now.addingTimeInterval(-60)) }

    func with(_ edit: (inout OwnerCheckView) -> Void) -> OwnerCheckView {
        var v = ok
        edit(&v)
        return v
    }

    @Test func unknownIsNotZero() throws {
        let unknown = try #require(WaitingCardModel.of(.gated, with { $0.state = .held }, now: now))
        #expect(unknown.counts == nil && unknown.held == true)
        let zero = try #require(WaitingCardModel.of(.gated, with { $0.state = .held; $0.waiting = WaitingCounts() }, now: now))
        #expect(zero.counts == WaitingCounts())
        let waiting = with { $0.waiting = WaitingCounts(messages: 3, requests: 1, other: 2) }
        let some = try #require(WaitingCardModel.of(.gated, waiting, now: now))
        #expect(some.counts == WaitingCounts(messages: 3, requests: 1, other: 2))
    }

    @Test func shownWheneverTheGateIsUp() throws {
        // Past the deadline by the clock while the vault still said ok (the app came back after it): shown, unknown.
        let byClock = try #require(WaitingCardModel.of(.gated, ok, now: now))
        #expect(byClock.counts == nil && byClock.held == true)
        // The hold is off: due, with its note.
        #expect(WaitingCardModel.of(.gated, with { $0.state = .due; $0.hold = false }, now: now)?.held == false)
        #expect(WaitingCardModel.of(.gated, with { $0.hold = false }, now: now)?.held == false)
        // Nothing known of the vault at all: still the card, without a note.
        #expect(WaitingCardModel.of(.gated, nil, now: now) == WaitingCardModel(counts: nil, held: nil))
        // Not for a check the member asked for.
        #expect(WaitingCardModel.of(.voluntary, ok, now: now) == nil)
        #expect(WaitingCardModel.of(.holdOff, ok, now: now) == nil)
    }

    /// The shell's gate: past the deadline by the vault's state or by the phone's clock.
    @Test func theGateFollowsTheClock() {
        let v = OwnerCheckView(state: .ok, deadline: now.addingTimeInterval(1_800))
        #expect(OwnerCheckGate.of(v, now: now) == OwnerCheckGate(gated: false, warning: true, holdOff: false))
        #expect(OwnerCheckGate.of(v, now: now.addingTimeInterval(1_800)).gated)
        #expect(!OwnerCheckGate.of(nil, now: now).gated)
    }
}
