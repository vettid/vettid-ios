import Foundation
import Testing
@testable import VettIDData

/// The end of a recovery the vault answered `ok` (release R): the open app, setup finished on a recovered phone, and never
/// over a lock asked for meanwhile (vettid-android `RecoveryOpenFinishTest`).
@MainActor
@Suite struct RecoveryOpenFinishTests {
    let finishing = AppPhase.setup(.finishing)

    /// A vault and an account record as ``VaultManager`` has them, with the steps taken in [steps].
    @MainActor
    final class Ports: RecoveryOpenFinish.Ports {
        let unlocked: AppPhase
        let gateOpen: Bool
        var steps: [String] = []
        var phase: AppPhase = .setup(.recovering)
        var overtakenNow = RecoveryOpenFinish.Overtaken.no
        /// Run once, after ``afterUnlocked()``: a lock asked for while the phase was computed.
        var onAfterUnlocked: () -> Void = {}
        /// Run when ``finishSetup()`` is called, before its gate: a lock asked for between the phase and the finish.
        var onFinishSetup: () -> Void = {}
        /// Run while the account record is written, after the gate passed: a lock asked for during the write.
        var onRecordWrite: () -> Void = {}

        init(unlocked: AppPhase, gateOpen: Bool = true) {
            self.unlocked = unlocked
            self.gateOpen = gateOpen
        }

        func overtaken() -> RecoveryOpenFinish.Overtaken { overtakenNow }

        func afterUnlocked() async throws -> AppPhase {
            steps.append("afterUnlocked")
            defer { onAfterUnlocked() }
            return unlocked
        }

        func publish(_ phase: AppPhase) {
            steps.append("publish \(phase)")
            self.phase = phase
        }

        /// As the manager's `finishSetupGated`: the gate, the record's write, then the checks again before the open phase.
        func finishSetup() async throws -> Bool {
            steps.append("finishSetup")
            onFinishSetup()
            let allowed = FinishSetupGate.allows(phase, lockPending: overtakenNow == .lockPending, finishingMove: false)
            guard gateOpen, allowed else { return false }
            onRecordWrite()
            if overtakenNow != .no { return false }
            phase = .unlocked
            return true
        }
    }

    func failure(_ p: Ports) async -> VaultFailure? {
        do {
            try await RecoveryOpenFinish.run(p)
            return nil
        } catch let f as VaultFailure {
            return f
        } catch {
            Issue.record("not a VaultFailure: \(error)")
            return nil
        }
    }

    /// A recovered phone is a new install: the unlock ends in finishing, and setup is finished here.
    @Test func aRecoveredPhoneFinishesSetupAndOpens() async throws {
        let p = Ports(unlocked: finishing)
        try await RecoveryOpenFinish.run(p)
        #expect(p.steps == ["afterUnlocked", "publish \(finishing)", "finishSetup"])
        #expect(p.phase == .unlocked)
    }

    /// A phone whose setup was complete opens at once; setup is not finished twice.
    @Test func aSetUpPhoneOpensWithoutFinishingSetup() async throws {
        let p = Ports(unlocked: .unlocked)
        try await RecoveryOpenFinish.run(p)
        #expect(p.steps == ["afterUnlocked", "publish \(AppPhase.unlocked)"])
        #expect(p.phase == .unlocked)
    }

    /// A lock pending before anything: locked, nothing of the open computed or published, and the caller is told.
    @Test func aPendingLockComesFirst() async {
        let p = Ports(unlocked: finishing)
        p.overtakenNow = .lockPending
        let f = await failure(p)
        #expect(f?.code == MoveCodes.lockPending && f?.kind == .noResponse)
        #expect(p.steps == ["publish \(AppPhase.locked)"] && p.phase == .locked)
    }

    /// A lock asked for while the phase was computed: its locked phase is never overwritten with the open one.
    @Test func aLockDuringTheUnlocksEndIsNotOverwritten() async {
        let p = Ports(unlocked: finishing)
        p.onAfterUnlocked = { p.overtakenNow = .lockPending }
        let f = await failure(p)
        #expect(f?.code == MoveCodes.lockPending)
        #expect(p.steps == ["afterUnlocked", "publish \(AppPhase.locked)"] && p.phase == .locked)
    }

    /// A lock asked for after the phase and before the finish: the gate refuses, the phone is locked, and it says so.
    @Test func aLockBeforeTheFinishIsAFailureNotASilentStop() async {
        let p = Ports(unlocked: finishing)
        p.onFinishSetup = { p.overtakenNow = .lockPending }
        let f = await failure(p)
        #expect(f?.code == MoveCodes.lockPending && p.phase == .locked)
    }

    /// A lock asked for while the record is written, after the gate passed (it publishes locked itself): never the open
    /// phase over it; locked, and the caller is told.
    @Test func aLockDuringTheRecordWriteIsNotOverwritten() async {
        let p = Ports(unlocked: finishing)
        p.onRecordWrite = {
            p.phase = .locked
            p.overtakenNow = .lockPending
        }
        let f = await failure(p)
        #expect(f?.code == MoveCodes.lockPending && p.phase == .locked)
        #expect(p.steps.last == "publish \(AppPhase.locked)")
    }

    /// A wipe (or a lock already confirmed) while the record is written: what it published stands, and a failure.
    @Test func aWipeDuringTheRecordWriteStands() async {
        let p = Ports(unlocked: finishing)
        p.onRecordWrite = {
            p.phase = .signedOut
            p.overtakenNow = .other
        }
        let f = await failure(p)
        #expect(f?.code == MoveCodes.notOpened && f?.kind == .other && p.phase == .signedOut)
    }

    /// The gate refused for another reason ("Finish the move" running): not opened, and a failure.
    @Test func aRefusedFinishIsAFailure() async {
        let p = Ports(unlocked: finishing, gateOpen: false)
        let f = await failure(p)
        #expect(f?.code == MoveCodes.notOpened && p.phase == finishing)
    }

    /// A wipe or a confirmed lock since the open began: what it published stands.
    @Test func aWipeMeanwhilePublishesNothing() async {
        let p = Ports(unlocked: finishing)
        p.onAfterUnlocked = { p.overtakenNow = .other }
        p.phase = .signedOut
        let f = await failure(p)
        #expect(f?.code == MoveCodes.notOpened && p.steps == ["afterUnlocked"] && p.phase == .signedOut)
    }

    /// The unlock did not end where an `ok` leaves it (the credential not here): published, never opened, a failure.
    @Test func anUnlockThatDidNotEndInSetupIsAFailure() async {
        let needs = AppPhase.setup(.needsCredential)
        let p = Ports(unlocked: needs)
        let f = await failure(p)
        #expect(f?.code == MoveCodes.notOpened && p.phase == needs)
    }
}
