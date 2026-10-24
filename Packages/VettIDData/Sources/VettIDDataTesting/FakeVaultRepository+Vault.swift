import Foundation
import VettIDAltChan
import VettIDData

// TEST ONLY. ``FakeVaultRepository`` as the vault and as a move (vettid-android `FakeVault`).

extension FakeVaultRepository: VaultRepository {
    public var usesPhoneSecret: Bool { phoneSecret }
    public var movedIn: Bool { movedInFlag }
    public var recoveryOffered: Bool { recoveryOfferedValue }

    public func retryLock() { calls.append("retryLock") }

    public func lockAgain() async {
        calls.append("lockAgain")
        lockNotice = .unconfirmed(askedAt: Date(timeIntervalSince1970: 0), attempts: 0)
    }

    public func dismissLockNotice() {
        calls.append("dismissLockNotice")
        lockNotice = .none
    }

    public func acknowledgeFinishMoveFailure() { finishMoveFailure = nil }

    public func acknowledgeMovedBack() {
        calls.append("acknowledgeMovedBack")
        movedBack = false
    }

    public func dismissRotateOffer() { rotateOffered = false }

    public func waitForChangeCheck(_ waiter: AnyObject?) { changeCheckWaiter = waiter }

    public var changeCheckAwaited: Bool { changeCheckWaiter != nil }

    public func acknowledgeChangeCheck() {
        calls.append("acknowledgeChangeCheck")
        if changeCheck?.undecided == false { changeCheck = nil }
    }

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
        renewSecretSuggested = false
    }

    public func dismissRenewSuggestion() {
        calls.append("dismissRenewSuggestion")
        renewSecretSuggested = false
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
        if r == .success {
            phase = .unlocked
            unlockPinStep = .pin
        }
        if r == .newPinNeeded { unlockPinStep = .new }
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
        if r == .success { checkAfterUnlock() }
        return r
    }

    /// As the vault manager: held (the gate's text, nothing sent), else a PIN taken before a change is sent nothing, else
    /// `vault.lock` and the unlock.
    public func finishMove(pin: String, taken: Int?) async throws -> UnlockAttempt {
        if let finishMoveHold { throw VaultFailure(finishMoveHold, code: "change_checking") }
        finishMoveTaken.append(taken)
        if let taken, taken != pinGeneration {
            return .failed(.credentialUnsettled, code: "pin_taken_before_change")
        }
        try await lock()
        return try await unlock(pin: pin, approve: nil, cancelRecovery: false)
    }

    public func lock() async throws {
        try call("lock")
        phase = .locked
    }

    public func overview() async throws -> VaultOverview {
        try call("overview")
        if let overviewGate { try await overviewGate.value() }
        return overviewValue
    }

    public func changePin(pin: String, newPin: String) async throws {
        try call("changePin")
        lastPin = newPin
    }

    public func changePin(pin: String, newPin: String, password: String) async throws {
        try call("changePin")
        lastPinChange = (pin, password)
        lastPin = newPin
        rotateOffered = true // as the real one (ANDROID-PLAN "Transfer")
    }

    public func deleteVault(pin: String, password: String) async throws {
        try call("deleteVault")
        lastPin = pin
        lastPassword = password
        // As the real one: "being deleted" (nothing is erased until the member confirms the removal there).
        deletion = VaultDeletion(since: Date(), until: Date().addingTimeInterval(600))
        phase = .deleting
    }

    public func checkVaultDeleted() async throws -> DeletionCheck {
        try call("checkVaultDeleted")
        return deletionCheck
    }

    public func recovery() async throws -> RecoveryView? {
        try call("recovery")
        return recoveryValue
    }

    public func attestationInfo() async throws -> AttestationInfo {
        try call("attestationInfo")
        return attestationValue
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
        if let recoveryFinishError { throw recoveryFinishError }
        if recoveryLockPending {
            phase = .locked
            throw VaultFailure(.noResponse, code: MoveCodes.lockPending)
        }
        phase = recoveryOpenLeavesFinishing ? .setup(.finishing) : .unlocked
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
        if let transferCreateGate { try await transferCreateGate.value() }
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
        // As a real call would: a cancelled caller sends nothing.
        try Task.checkCancellation()
        try call("transferReject")
        lastTransferRejected = transferID
    }
}
