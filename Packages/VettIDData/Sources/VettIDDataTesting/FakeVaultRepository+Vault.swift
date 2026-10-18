import Foundation
import VettIDAltChan
import VettIDData

// TEST ONLY. ``FakeVaultRepository`` as the vault and as a move (vettid-android `FakeVault`).

extension FakeVaultRepository: VaultRepository {
    public var usesPhoneSecret: Bool { phoneSecret }
    public var movedIn: Bool { movedInFlag }
    public var recoveryOffered: Bool { recoveryOfferedValue }

    public func retryLock() { calls.append("retryLock") }

    public func dismissLockNotice() {
        calls.append("dismissLockNotice")
        lockNotice = .none
    }

    public func acknowledgeFinishMoveFailure() { finishMoveFailure = nil }

    public func acknowledgeMovedBack() {
        calls.append("acknowledgeMovedBack")
        movedBack = false
    }

    public func acknowledgeMoveNotDone() {
        calls.append("acknowledgeMoveNotDone")
        moveNotDone = false
    }

    public func dismissRotateOffer() { rotateOffered = false }

    public func acknowledgeMovedAway() {
        calls.append("acknowledgeMovedAway")
        movedAway = false
    }

    public func enroll(pin: String, onStep: @MainActor (EnrollStep) -> Void) async throws {
        try call("enroll")
        lastPin = pin
        for s in [EnrollStep.enroll, .waitForVault, .handshake] { onStep(s) }
    }

    public func cancelDeletion() async throws -> Bool {
        try call("cancelDeletion")
        let was = pendingDeletion?.cancellable == true
        if was { pendingDeletion = nil }
        return was
    }

    public func createCredential(password: String, backup: Bool, onStep: @MainActor (EnrollStep) -> Void) async throws {
        try call("createCredential")
        lastPassword = password
        lastBackup = backup
        for s in [EnrollStep.createCredential, .backup, .confirm] { onStep(s) }
        phase = .setup(.finishing)
    }

    public func createCredential(password: String, backup: Bool, pin: String?, onStep: @MainActor (EnrollStep) -> Void) async throws {
        lastCredentialPin = phoneSecret ? pin : nil
        try await createCredential(password: password, backup: backup, onStep: onStep)
    }

    public func renewPhoneSecret(pin: String, password: String) async throws {
        try call("renewPhoneSecret")
        lastRenew = (pin, password)
    }

    public func finishSetup() async throws {
        try call("finishSetup")
        phase = .unlocked
    }

    public func preflight() async throws -> PreflightInfo {
        try call("preflight")
        return preflightInfo
    }

    public func unlock(pin: String, approve: ReleaseView?, cancelRecovery: Bool) async throws -> UnlockAttempt {
        try call("unlock")
        lastPin = pin
        lastApproved = approve
        lastCancelRecovery = cancelRecovery
        let r = unlockResults.isEmpty ? .success : unlockResults.removeFirst()
        if case .failed = r {} else { refusedByVault = false } // a sealed answer, as the vault manager
        if r == .success { phase = .unlocked }
        return r
    }

    public func unlockWithEarlierSecret(pin: String) async throws -> UnlockAttempt {
        let r = try await unlock(pin: pin, approve: nil, cancelRecovery: false)
        calls.append("unlockWithEarlierSecret")
        return r
    }

    public func unlockCancellingRecovery(pin: String, password: String, approve: ReleaseView?) async throws -> UnlockAttempt {
        lastCancelCheckPassword = password
        return try await unlock(pin: pin, approve: approve, cancelRecovery: true)
    }

    public func unlockWithCheck(pin: String, password: String, approve: ReleaseView?, cancelRecovery: Bool) async throws -> UnlockAttempt {
        lastPassword = password
        let r = try await unlock(pin: pin, approve: approve, cancelRecovery: cancelRecovery)
        calls.append("unlockWithCheck")
        return r
    }

    public func lock() async throws {
        try call("lock")
        phase = .locked
    }

    public func overview() async throws -> VaultOverview {
        try call("overview")
        return overviewValue
    }

    public func changePin(pin: String, newPin: String) async throws {
        try call("changePin")
        lastPin = newPin
    }

    public func deleteVault(pin: String, password: String) async throws {
        try call("deleteVault")
        lastPin = pin
        lastPassword = password
        phase = .signedOut // a new vault needs a new setup code
    }

    public func recovery() async throws -> RecoveryView? {
        try call("recovery")
        return recoveryValue
    }

    public func attestationInfo() async throws -> AttestationInfo {
        try call("attestationInfo")
        return AttestationInfo(
            environment: "test",
            keyPresent: true,
            keyLevel: "STRONG_BOX",
            strongBoxAvailable: true,
            attestationVersion: 300,
            verifiedBoot: "SelfSigned",
            deviceLocked: true,
            bootKeyFingerprint: "4e8e e8f7",
            lastRelease: 3,
            lastReleaseFingerprint: "aaaa bbbb"
        )
    }
}

extension FakeVaultRepository: MoveRepository {
    public func recoveryStage() async throws -> RecoveryStage {
        try call("recoveryStage")
        return recoveryStageValue
    }

    public func registerRecovery(_ code: RecoveryCode) async throws -> RecoveryRegistration {
        try call("registerRecovery")
        lastRegistered = code
        let r = registrations.isEmpty ? .registered(emailHint: emailHint) : registrations.removeFirst()
        if case .registered = r { phase = .setup(.recovering) }
        return r
    }

    public func registerTypedRecovery(_ typed: TypedRecoveryCode) async throws -> RecoveryRegistration {
        try call("registerTypedRecovery")
        lastTyped = typed
        let r = registrations.isEmpty ? .registered(emailHint: emailHint) : registrations.removeFirst()
        switch r {
        case .registered:
            phase = .setup(.recovering)
            return r
        // As the vault manager: a refusal after the claim names the recovery; the claim's own 404 names none.
        case .refused(let code, let id) where code != "no_recovery":
            return .refused(code: code, recoveryID: id ?? typedRecoveryID)
        case .refused:
            return r
        }
    }

    public func recoveryPreflight() async throws -> PreflightInfo {
        try call("recoveryPreflight")
        return preflightInfo
    }

    public func recoveryCredentialBackup() async throws -> Bool? {
        try call("recoveryCredentialBackup")
        return recoveryCredentialBackupValue
    }

    public func recoveryUnlock(pin: String, approve: ReleaseView?) async throws -> UnlockAttempt {
        try call("recoveryUnlock")
        lastPin = pin
        lastApproved = approve
        return recoveryUnlockResults.isEmpty ? .success : recoveryUnlockResults.removeFirst()
    }

    public func abandonRecovery() async throws {
        try call("abandonRecovery")
        phase = .signedOut
    }

    public func recoverCredential(password: String) async throws -> RecoverOutcome {
        try call("recoverCredential")
        lastPassword = password
        if recoverOutcome == .recovered { phase = .setup(.finishing) }
        return recoverOutcome
    }

    public func recoveryOpen(pin: String, password: String) async throws -> RecoveryOpenOutcome {
        try call("recoveryOpen")
        lastPin = pin
        lastPassword = password
        return recoveryOpenOutcomes.isEmpty ? RecoveryOpenOutcome("ok", used: 1) : recoveryOpenOutcomes.removeFirst()
    }

    public func recoveryOpened() async throws -> Bool { recoveryOpenedValue }

    public func resumeLostOk(pin: String) async throws -> RecoveryOpenOutcome {
        try call("resumeLostOk")
        lastPin = pin
        return lostOkOutcomes.isEmpty ? RecoveryOpenOutcome("ok", used: 2, attemptUsed: false) : lostOkOutcomes.removeFirst()
    }

    public func finishRecoveryOpen() async throws {
        try call("finishRecoveryOpen")
        phase = .unlocked
    }

    public func transferIn(code: String) async throws -> String {
        try call("transferIn")
        lastTransferCode = code
        if let hs = transferHsResp { return try await hs.value() }
        return transferSas
    }

    public func awaitTransferIn() async throws -> Bool {
        try call("awaitTransferIn")
        try await transferApproval.value()
        phase = .setup(.finishing)
        return transferGaveUserGuid
    }

    public func abandonTransferIn() async throws { try call("abandonTransferIn") }

    public func transferCreate() async throws -> TransferOfferView {
        try call("transferCreate")
        return offer
    }

    public func awaitTransferPending(transferID: String, until: Date) async throws -> TransferPendingView? {
        try call("awaitTransferPending")
        return try await pendingTransfer.value()
    }

    public func transferApprove(transferID: String, pin: String, password: String, signer: String?) async throws -> Bool {
        try call("transferApprove")
        transferSigners.append(signer)
        let missing = transferSignerRequired != nil && signer == nil
        let wrong = signer != nil && signer != (transferSignerRequired ?? transferSignerClass)
        if missing || wrong { throw VaultFailure(.other, code: "signer_unconfirmed") }
        lastTransferApproved = transferID
        lastPin = pin
        lastPassword = password
        if transferConfirmed { phase = .signedOut } // the wipe: as freshly installed
        return transferConfirmed
    }

    public func transferReject(transferID: String) async throws {
        try call("transferReject")
        lastTransferRejected = transferID
    }
}
