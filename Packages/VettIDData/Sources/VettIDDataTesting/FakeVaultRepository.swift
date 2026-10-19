import Foundation
import Observation
import VettIDAltChan
import VettIDData

/// TEST ONLY. An in-memory account, vault and credential for view-model tests: every call is recorded in ``calls``;
/// ``fail`` makes the next call of a name throw; the unlock outcomes are scripted in ``unlockResults``. Observable, as
/// the real repositories are, so a view model's observation of ``phase`` and the other states can be tested. (VettID's
/// vault tests have a protocol-level `FakeVault`; this one stands in for the repositories.) Mirrors vettid-android
/// `FakeVault`, of whose profile part only the name change so far.
@MainActor
@Observable
public final class FakeVaultRepository: CustomStringConvertible {
    /// A string only this TEST ONLY target contains; `scripts/release-check.sh` refuses it in Release and Staging.
    public nonisolated static let testOnlyMarker = "VETTID TEST ONLY: the repository-level fake"

    /// Every call, by name, in order.
    public var calls: [String] = []
    /// A failure the next call of that name throws (once).
    public var fail: [String: VaultFailure] = [:]
    /// What the unlocks answer, in order; an empty queue answers ``UnlockAttempt/success``.
    public var unlockResults: [UnlockAttempt] = []

    // AccountRepository.
    public var phase: AppPhase
    public var account: AccountInfo?
    public let devHint: String? = nil
    public let apiOrigin = "https://account.vettid.org"
    /// MEMBER-API 1.2.0: the vault service paused (the banner).
    public var servicePaused = false
    /// What ``redeemSetupCode(_:)`` answers (`email_hint`); the phase it moves to.
    public var emailHint = "m***@example.com"
    public var phaseAfterRedeem: AppPhase = .setup(.newVault)
    public var lastRedeemed: SetupCodeInput?

    // VaultRepository.
    /// Set by a test: the open app was sent to the unlock screen after repeated relay refusals.
    public var refusedByVault = false
    public var lockNotice: LockNotice = .none
    public var pendingDeletion: DeletionView?
    public var preflightInfo = PreflightInfo(routed: release(3), lastNumber: 3, softwareUpdated: false, rollback: false, offer: nil)
    public var overviewValue = VaultOverview(
        vaultID: "0123456789abcdef0123456789abcdef",
        state: "unlocked",
        release: nil,
        lastRelease: 3,
        recoveryState: nil,
        provisional: false,
        devices: 1,
        connections: 0
    )
    public var recoveryValue: RecoveryView?
    /// Set: ``overview()`` waits for it (a status read still under way).
    public var overviewGate: TestDeferred<Void>?
    /// What ``attestationInfo()`` answers: an Android phone's, by default.
    public var attestationValue = AttestationInfo(
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
    public var lastPin: String?
    public var lastPassword: String?
    public var lastBackup: Bool?
    public var lastApproved: ReleaseView?
    public var lastCancelRecovery = false
    /// (iPhone, IOS-PLAN §6.3 item 5) Whether a replaced phone-secret record exists for the earlier-secret step.
    public var earlierSecretOffered = false
    public var releaseUpdateHeld = false

    // Release R.
    /// This phone holds a phone secret (a vault of release R).
    public var phoneSecret = false
    /// The vault came here by a direct transfer (``movedIn``).
    public var movedInFlag = false
    /// (§11.10.9) Whether the vault's release offers recovery.
    public var recoveryOfferedValue = true
    /// (STAGING-TIME-SCALE §5.2) The vault's time scale (``VaultRepository/timeScale``, ``OwnerCheckRepository/timeScale``).
    public var timeScale: UInt64 = 1
    /// The PIN the last `credential.create` and `credential.password.change` carried (release R).
    public var lastCredentialPin: String?
    public var lastPasswordChangePin: String?
    /// The password the last unlock that cancelled a recovery sent with its owner check (release R).
    public var lastCancelCheckPassword: String?
    /// The PIN and password of the last `vault.secret.renew` (release R).
    public var lastRenew: (pin: String, password: String)?
    /// (iPhone, IOS-PLAN §6.3 item 5) The earlier-secret step opened the vault: the prompt for a new phone secret.
    public var renewSecretSuggested = false
    /// What ``checkVaultDeleted()`` finds after a deletion whose answer was lost (deleted: VettID's data on this phone erased).
    public var deletionCheck = DeletionCheck.undecided
    public var transferKeptSince: Date?
    public var finishMovePending = false
    public var finishingMove = false
    public var finishMoveFailure: FailureKind?
    public var movedBack = false
    public var moveNotDone = false
    public var rotateOffered = false
    public var movedAway = false
    /// (VAULT-MESSAGING §11.14.9 "A lost answer") Where the decision of a lost change stands, set by a test.
    public var changeCheck: ChangeCheck?
    /// Which PIN the unlock asks for; ``UnlockAttempt/newPinNeeded`` moves it to ``UnlockPinStep/new``.
    public var unlockPinStep: UnlockPinStep = .pin
    /// The change screen waiting for the decision (held weakly).
    @ObservationIgnored public weak var changeCheckWaiter: AnyObject?

    // OwnerCheckRepository.
    public var ownerCheck: OwnerCheckView?
    public var lockedByOwnerCheck = false
    public var unlockCheckOutcome: OwnerCheckOutcome?
    public var notices: [OwnerCheckNotice] = []
    public var presenceUnrecorded = false
    public var checkAfterCancel = false
    /// Scripted answers to ``check(pin:password:holdOff:)`` (default: passed).
    public var checkResults: [OwnerCheckOutcome] = []
    public var lastHoldOff: HoldOff?
    public var lastInterval: Int64?
    /// What ``clearAppData()`` answers.
    public var clearAppDataResult = true

    // CredentialRepository.
    public var alarm: CredentialAlarm?
    public var unlockWindow: Date?
    public var credential = CredentialStatus(
        exists: true,
        version: 2,
        keyFingerprint: "abc",
        updatedAt: "2026-10-04T12:00:00Z",
        alarm: nil,
        backup: true,
        unlockTtlSeconds: 300,
        criticalItems: 0
    )
    public var lastNewPassword: String?
    /// The answer of the last ``confirmAlarm(mine:)``.
    public var lastAlarmMine: Bool?
    /// The last release R `pin.change`: the current PIN and the password (``lastPin`` is the new PIN).
    public var lastPinChange: (pin: String, password: String)?

    // ProfileRepository.
    /// Scripted answers to ``changeName(pin:password:firstName:lastName:)`` (default: a pending request with the next seq).
    public var nameResults: [NameChangeOutcome] = []
    public var lastNames: (first: String, last: String)?
    var nameSeq: Int64 = 0

    // MoveRepository: recovery.
    public var recoveryStageValue: RecoveryStage = .code
    /// What the registrations answer, in order; an empty queue answers ``RecoveryRegistration/registered(emailHint:)``.
    public var registrations: [RecoveryRegistration] = []
    public var lastRegistered: RecoveryCode?
    /// The typed code last given to ``registerTypedRecovery(_:)``, and the recovery its claim "named" for a refusal.
    public var lastTyped: TypedRecoveryCode?
    public var typedRecoveryID: String? = "01JA0RECVERY0000000000001X"
    public var recoveryUnlockResults: [UnlockAttempt] = []
    public var recoverOutcome: RecoverOutcome = .recovered
    /// The recovery unlock's `credential_backup` (nil: an older vault that does not send it).
    public var recoveryCredentialBackupValue: Bool?
    /// What ``recoveryOpen(pin:password:)`` answers, in order; an empty queue answers `ok`.
    public var recoveryOpenOutcomes: [RecoveryOpenOutcome] = []
    public var recoveryOpenedValue = false
    public var recoveryAttemptsUsed: Int?
    /// What ``resumeLostOk(pin:)`` answers, in order; an empty queue answers `ok`.
    public var lostOkOutcomes: [RecoveryOpenOutcome] = []

    // MoveRepository: transfer.
    public var transferSas = "042817"
    /// What ``awaitTransferIn()`` answers: false as from a vault release that sends no `user_guid`.
    public var transferGaveUserGuid = true
    /// When set, the new phone's wait for the vault's `hs.resp` (and so the SAS) lasts until it completes.
    public var transferHsResp: TestDeferred<String>?
    public var lastTransferCode: String?
    /// Completes (or fails) the new phone's wait for the old phone's approval.
    public var transferApproval = TestDeferred<Void>()
    public var offer = TransferOfferView(
        transferID: "01JTRANSFER000000000000000",
        qrPayload: #"{"v":2,"t":"p"}"#,
        link: "eyJ2Ijoy",
        expiresAt: FakeVaultRepository.date("2026-10-05T12:10:00Z")
    )
    /// Completes the old phone's wait for `device.transfer.pending` (nil: the code expired).
    public var pendingTransfer = TestDeferred<TransferPendingView?>()
    public var lastTransferApproved: String?
    public var lastTransferRejected: String?
    /// Whether the vault's `device.unlinked{transferred}` follows an approval (and wipes this phone).
    public var transferConfirmed = true
    /// The class the vault wants confirmed (`device.transfer.pending.signer_changed`, VAULT-MESSAGING §11.7.1): as
    /// vettid-vault, an approval that does not name it is answered `signer_unconfirmed` before anything is checked or
    /// counted, and one that names a class the new app does not have is refused the same way.
    public var transferSignerRequired: String?
    /// The new app's class when the vault names one without requiring it (same signer).
    public var transferSignerClass: String?
    /// The `signer` of every approval sent, in order (nil: the member was absent).
    public var transferSigners: [String?] = []

    public nonisolated var description: String { Self.testOnlyMarker }

    public init(_ initial: AppPhase = .signedOut) {
        phase = initial
    }

    /// Records [name] and throws its scripted failure, if any.
    func call(_ name: String) throws {
        calls.append(name)
        if let f = fail.removeValue(forKey: name) { throw f }
    }

    /// A release whose PCR0 is its number, two digits at least, repeated.
    public nonisolated static func release(_ n: UInt64, status: String = "active") -> ReleaseView {
        let digits = String(n)
        let pcr0 = String(repeating: digits.count < 2 ? "0" + digits : digits, count: 48)
        return ReleaseView(number: n, pcr0: pcr0, status: status, endsAt: nil, notes: "https://vettid.org/releases/\(n)")
    }

    public nonisolated static func failure(_ kind: FailureKind, code: String? = nil, retry: Int64 = 0) -> VaultFailure {
        VaultFailure(kind, code: code, retryAfterSeconds: retry)
    }

    /// An ISO 8601 instant of the fixtures.
    public nonisolated static func date(_ iso: String) -> Date {
        (try? Date(iso, strategy: .iso8601)) ?? Date(timeIntervalSince1970: 0)
    }
}

extension FakeVaultRepository: AccountRepository {
    public func refresh() async throws { try call("refresh") }

    public func redeemSetupCode(_ code: SetupCodeInput) async throws -> String {
        try call("redeemSetupCode")
        lastRedeemed = code
        account = AccountInfo(emailHint: emailHint)
        phase = phaseAfterRedeem
        return emailHint
    }

    public func forgetSetupCode() async throws {
        try call("forgetSetupCode")
        account = nil
        phase = .signedOut
    }

    public func forgetMissingVault() async throws {
        try call("forgetMissingVault")
        phase = .signedOut
    }

    public func eraseThisPhone() async throws {
        try call("eraseThisPhone")
        account = nil
        phase = .signedOut
    }

    public func clearAppData() async -> Bool {
        calls.append("clearAppData")
        if clearAppDataResult {
            account = nil
            phase = .signedOut
        }
        return clearAppDataResult
    }
}

extension FakeVaultRepository: OwnerCheckRepository {
    private func passed() -> OwnerCheckOutcome {
        if var v = ownerCheck {
            v.state = .ok
            v.deadline = Date().addingTimeInterval(86_400)
            v.failures = 0
            v.waiting = nil
            ownerCheck = v
        }
        return .passed
    }

    public func refreshOwnerCheck() async throws { try call("refreshOwnerCheck") }

    public func check(pin: String, password: String, holdOff: HoldOff?) async throws -> OwnerCheckOutcome {
        try call("check")
        lastPin = pin
        lastPassword = password
        lastHoldOff = holdOff
        let r = checkResults.isEmpty ? passed() : checkResults.removeFirst()
        if r == .passed, let holdOff, var v = ownerCheck {
            v.hold = false
            v.holdOffUntil = holdOff.until
            ownerCheck = v
        }
        return r
    }

    public func setCheckInterval(seconds: Int64) async throws {
        try call("setCheckInterval")
        lastInterval = seconds
        ownerCheck?.intervalSeconds = seconds
    }

    public func turnHoldOn() async throws {
        try call("turnHoldOn")
        ownerCheck?.hold = true
        ownerCheck?.holdOffUntil = nil
    }

    public func consumeUnlockCheckOutcome() { unlockCheckOutcome = nil }

    public func consumeCheckAfterCancel() { checkAfterCancel = false }

    public func dismissNotices() async throws {
        try call("dismissNotices")
        notices = []
    }

    /// The outcome of the check an unlock past the deadline sent (``unlockWithCheck(pin:password:approve:cancelRecovery:)``).
    func checkAfterUnlock() {
        unlockCheckOutcome = checkResults.isEmpty ? passed() : checkResults.removeFirst()
    }
}

extension FakeVaultRepository: CredentialRepository {
    public func status() async throws -> CredentialStatus {
        try call("status")
        var c = credential
        c.alarm = alarm
        return c
    }

    public func openUnlockWindow(password: String) async throws {
        try call("openUnlockWindow")
        lastPassword = password
        unlockWindow = Self.date("2026-10-04T12:05:00Z")
    }

    public func closeUnlockWindow() async throws {
        try call("closeUnlockWindow")
        unlockWindow = nil
    }

    public func changePassword(_ password: String, newPassword: String) async throws {
        try call("changePassword")
        lastPassword = newPassword
    }

    public func changePassword(_ password: String, newPassword: String, pin: String?) async throws {
        lastPasswordChangePin = phoneSecret ? pin : nil
        try await changePassword(password, newPassword: newPassword)
        if phoneSecret { rotateOffered = true } // as the real one (ANDROID-PLAN "Transfer")
    }

    public func rotate(password: String) async throws {
        try call("rotate")
        lastPassword = password
        alarm = nil
        rotateOffered = false
        unlockWindow = nil
    }

    public func newCredential(pin: String, password: String, newPassword: String) async throws {
        try call("newCredential")
        lastPin = pin
        lastPassword = password
        lastNewPassword = newPassword
    }

    public func setBackup(_ on: Bool) async throws {
        try call("setBackup")
        lastBackup = on
        credential.backup = on
    }

    public func setUnlockTtl(seconds: Int) async throws {
        try call("setUnlockTtl")
        credential.unlockTtlSeconds = seconds
    }

    public func confirmAlarm(mine: Bool) async throws {
        try call("confirmAlarm")
        lastAlarmMine = mine
        guard alarm != nil else { throw VaultFailure(.notFound) }
        alarm?.state = CredentialAlarm.stateRotationRequired
    }
}
