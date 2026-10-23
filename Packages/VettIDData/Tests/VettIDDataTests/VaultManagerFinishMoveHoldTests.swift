import Foundation
import Observation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// Whether a value read inside `withObservationTracking` changed since: what a follower of the real manager sees.
@MainActor
final class ObservedChanges {
    private(set) var count = 0

    /// Starts watching [read]; the next change of what it reads is counted once, and watching goes on.
    func watch(_ read: @escaping @MainActor () -> Void) {
        withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor in
                self?.count += 1
                self?.watch(read)
            }
        }
    }
}

/// "Finish the move" is held while a PIN or password change is being decided or the PIN is uncertain (VAULT-MESSAGING
/// 0.45.0 §11.14.9 step 2): ``VaultManager/finishMoveHold`` is observable, so that a follower of the real manager (not
/// only the fake) sees it change wherever a change starts or ends, or the PIN becomes uncertain or settles. Mirrors
/// vettid-android `FinishMoveHoldTest`.
@MainActor
@Suite(.serialized) struct VaultManagerFinishMoveHoldTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let newPin = "518293"
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
        #expect(m.finishMoveHold == nil)
    }

    /// A follower sees an unresolved change hold the move, and its decision lift the hold. Nothing is sent meanwhile.
    @Test func aFollowerSeesAnUnresolvedChangeHoldAndLiftIt() async throws {
        defer { phone.close() }
        try await setUp()
        let seen = ObservedChanges()
        seen.watch { _ = m.finishMoveHold }
        service.loseAnswers([VaultApi.typePinChange, "credential.version"], from: VaultApi.typePinChange)
        _ = await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }
        // The gate's text: the change is being checked, or the check could not reach the vault.
        let kind = try #require(m.finishMoveHold)
        #expect([FailureKind.changeChecking, .changeUnresolved].contains(kind) && kind == m.moveHold()?.kind)
        #expect(await eventually { seen.count >= 1 })
        // "Finish the move" is refused with the hold's text, and nothing is locked or sent.
        let unlocks = service.unlocks.count
        let locks = (service.memberLocks, service.relayLocks)
        let held = await vaultFailure { _ = try await m.finishMove(pin: pin) }
        #expect(held?.kind == kind && service.unlocks.count == unlocks && m.phase == .unlocked)
        #expect((service.memberLocks, service.relayLocks) == locks && !m.finishingMove)
        // The change is decided: the hold lifts, and the follower sees it.
        let before = seen.count
        service.loseAnswers([])
        await m.checkUnresolvedChange()
        #expect(m.changeCheck == ChangeCheck(.pin, .applied) && m.finishMoveHold == nil)
        #expect(await eventually { seen.count > before })
    }

    /// A change on its way holds the move too (``VaultManager/sendingChange``), and the hold is gone when it is answered.
    @Test func aChangeOnItsWayHoldsTheMoveAndItsAnswerLiftsTheHold() async throws {
        defer { phone.close() }
        try await setUp()
        let seen = ObservedChanges()
        seen.watch { _ = m.finishMoveHold }
        try await m.changePin(pin: pin, newPin: newPin, password: password)
        #expect(m.finishMoveHold == nil)
        // It was held while it ran: the follower was told at least twice (held, then lifted).
        #expect(await eventually { seen.count >= 2 })
    }

    /// An uncertain PIN holds the move; the two-step unlock settles it and lifts the hold.
    @Test func anUncertainPinHoldsTheMoveUntilTheUnlockSettlesIt() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typePinChange, "credential.version"], from: VaultApi.typePinChange)
        _ = await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }
        service.moveCredentialWithoutTheApp()
        try await phone.restart()
        service.loseAnswers([])
        let seen = ObservedChanges()
        seen.watch { _ = m.finishMoveHold }
        await m.checkUnresolvedChange(evenLocked: true)
        #expect(m.changeCheck == ChangeCheck(.pin, .ended))
        #expect(m.finishMoveHold == .pinUncertain)
        #expect(await eventually { seen.count >= 1 })
        let before = seen.count
        try await m.refresh()
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .newPinNeeded)
        #expect(try await m.unlock(pin: newPin) == .success)
        #expect(m.finishMoveHold == nil)
        #expect(await eventually { seen.count > before })
    }
}
