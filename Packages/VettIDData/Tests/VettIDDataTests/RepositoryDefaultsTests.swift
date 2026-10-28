import Foundation
import Observation
import Testing
import VettIDAltChan
import VettIDData

/// The protocol defaults (vettid-android's interface defaults): what a repository that does not implement a later
/// operation answers.
@MainActor
@Suite struct RepositoryDefaultsTests {
    /// Implements only the required operations, recording them.
    @MainActor
    @Observable
    final class Minimal: AccountRepository, VaultRepository, CredentialRepository, MoveRepository {
        var calls: [String] = []
        let phase = AppPhase.locked
        let account: AccountInfo? = nil
        let devHint: String? = nil
        let apiOrigin = "https://account.vettid.org"
        let refusedByVault = false
        let alarm: CredentialAlarm? = nil
        let unlockWindow: Date? = nil

        func refresh() async throws {}
        func redeemSetupCode(_ code: SetupCodeInput) async throws -> String { "" }
        func forgetSetupCode() async throws {}
        func eraseThisPhone() async throws {}
        func enroll(pin: String, onStep: @MainActor (EnrollStep) -> Void) async throws {}
        func createCredential(password: String, backup: Bool, onStep: @MainActor (EnrollStep) -> Void) async throws {
            calls.append("createCredential")
        }
        func finishSetup() async throws {}
        func preflight() async throws -> PreflightInfo { throw VaultFailure(.other) }
        func unlock(pin: String, approve: ReleaseView?, cancelRecovery: Bool) async throws -> UnlockAttempt {
            calls.append("unlock(\(cancelRecovery))")
            return .success
        }
        func lock() async throws { calls.append("lock") }
        func forgetPairingPin() { calls.append("forgetPairingPin") }
        func overview() async throws -> VaultOverview { throw VaultFailure(.other) }
        func changePin(pin: String, newPin: String) async throws { calls.append("changePin") }
        func deleteVault(pin: String, password: String) async throws {}
        func recovery() async throws -> RecoveryView? { nil }
        func attestationInfo() async throws -> AttestationInfo { throw VaultFailure(.other) }
        func status() async throws -> CredentialStatus { throw VaultFailure(.other) }
        func openUnlockWindow(password: String) async throws {}
        func closeUnlockWindow() async throws {}
        func changePassword(_ password: String, newPassword: String) async throws { calls.append("changePassword") }
        func rotate(password: String) async throws {}
        func newCredential(pin: String, password: String, newPassword: String) async throws {}
        func setBackup(_ on: Bool) async throws {}
        func setUnlockTtl(seconds: Int) async throws {}
        func confirmAlarm(mine: Bool) async throws {}
        func recoveryStage() async throws -> RecoveryStage { .code }
        func registerRecovery(_ code: RecoveryCode) async throws -> RecoveryRegistration { .refused(code: "x") }
        func registerTypedRecovery(_ typed: TypedRecoveryCode) async throws -> RecoveryRegistration { .refused(code: "x") }
        func recoveryPreflight() async throws -> PreflightInfo { throw VaultFailure(.other) }
        func recoveryUnlock(pin: String, approve: ReleaseView?) async throws -> UnlockAttempt { .success }
        func recoveryCredentialBackup() async throws -> Bool? { nil }
        func recoverCredential(password: String) async throws -> RecoverOutcome { .recovered }
        func transferIn(code: String) async throws -> String { "" }
        func awaitTransferIn() async throws -> Bool { true }
        func abandonTransferIn() async throws {}
        func transferCreate() async throws -> TransferOfferView { throw VaultFailure(.other) }
        func awaitTransferPending(transferID: String, until: Date) async throws -> TransferPendingView? { nil }
        func transferApprove(transferID: String, pin: String, password: String, signer: String?) async throws -> Bool { true }
        func transferReject(transferID: String) async throws {}
    }

    private func kind(_ op: () async throws -> Void) async -> FailureKind? {
        do {
            try await op()
            return nil
        } catch let f as VaultFailure {
            return f.kind
        } catch {
            return .other
        }
    }

    @Test func laterOperationsAreNotSupported() async {
        let r = Minimal()
        #expect(await kind { try await r.changePin(pin: "1", newPin: "2", password: "p") } == .notSupported)
        #expect(await kind { try await r.renewPhoneSecret(pin: "1", password: "p") } == .notSupported)
        #expect(await kind { _ = try await r.recoveryOpen(pin: "1", password: "p") } == .notSupported)
        #expect(await kind { _ = try await r.resumeLostOk(pin: "1") } == .notSupported)
        #expect(r.calls.isEmpty)
    }

    @Test func theStatesDefaultToNothingToSay() async throws {
        let r = Minimal()
        #expect(!r.servicePaused && r.lockNotice == .none && r.pendingDeletion == nil)
        #expect(!r.usesPhoneSecret && !r.movedIn && r.recoveryOffered)
        #expect(r.transferKeptSince == nil && !r.finishMovePending && !r.finishingMove && r.finishMoveFailure == nil)
        #expect(!r.movedBack && !r.rotateOffered && !r.movedAway)
        #expect(r.recoveryAttemptsUsed == nil)
        #expect(try await !r.cancelDeletion())
        #expect(try await !r.recoveryOpened())
    }

    @Test func theNoOpDefaultsDoNothing() async throws {
        let r = Minimal()
        try await r.abandonRecovery()
        try await r.finishRecoveryOpen()
        try await r.forgetMissingVault()
        await r.refreshAccount()
        r.onForeground()
        r.retryLock()
        r.dismissLockNotice()
        r.acknowledgeFinishMoveFailure()
        r.acknowledgeMovedBack()
        r.dismissRotateOffer()
        r.acknowledgeMovedAway()
        #expect(r.calls.isEmpty && r.phase == .locked)
    }

    /// The default `finishMove(pin:taken:)` never drops `taken`: a PIN taken before a change is sent nothing.
    @Test func theDefaultFinishMoveRefusesAPinTakenBeforeAChange() async throws {
        let r = Minimal()
        #expect(try await r.finishMove(pin: "1", taken: 5) == .failed(.credentialUnsettled, code: "pin_taken_before_change"))
        #expect(r.calls.isEmpty)
        #expect(try await r.finishMove(pin: "1", taken: 0) == .success)
        #expect(try await r.finishMove(pin: "1", taken: nil) == .success)
    }

    @Test func theDefaultsFallBackToTheEarlierOperations() async throws {
        let r = Minimal()
        #expect(try await r.finishMove(pin: "1") == .success)
        #expect(r.calls == ["lock", "unlock(false)"])
        r.calls = []
        _ = try await r.unlockCancellingRecovery(pin: "1", password: "p")
        _ = try await r.unlockWithCheck(pin: "1", password: "p")
        _ = try await r.unlock(pin: "1")
        try await r.createCredential(password: "p", backup: true, pin: "1") { _ in }
        try await r.changePassword("p", newPassword: "q", pin: "1")
        #expect(r.calls == ["unlock(true)", "unlock(false)", "unlock(false)", "createCredential", "changePassword"])
    }
}
