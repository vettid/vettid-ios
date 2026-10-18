import Foundation
import Observation
import VettIDAltChan
import VettIDData

/// Drives onboarding (VAULT-MESSAGING 0.15.0 §11.12; the app never signs in): the setup code from the account portal,
/// scanned (or opened as its Universal Link) or typed with the account's email, redeemed with this phone's app key; the
/// account's masked email to confirm; then the vault: PIN, credential password, backup choice, enrollment with device
/// attestation, the first handshake, the credential, and the confirmation. The app-level phase
/// (``AccountRepository/phase``) decides where it starts. Mirrors vettid-android `OnboardingViewModel`.
///
/// The repositories' states are followed as Android collects its `StateFlow`s (the current value at once, then each
/// change); every task the model starts is its own and ends with it.
@MainActor
@Observable
public final class OnboardingViewModel: OnboardingActions {
    public private(set) var state: OnboardingState

    @ObservationIgnored let account: any AccountRepository
    @ObservationIgnored let vault: any VaultRepository
    @ObservationIgnored private let inbox: SetupLinkInbox
    /// Set once enrollment succeeded in this flow, so a retry resumes with the credential.
    @ObservationIgnored private var enrolled = false
    @ObservationIgnored private let followers = TaskBag()
    @ObservationIgnored private var work: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextWork = 0
    /// The scanned text whose redeem failed last (chosen; not in the spec): the camera keeps reading the same QR when the
    /// scanner comes back, so it is not redeemed again until another text is read or the scan screen is opened anew.
    @ObservationIgnored private var failedScan: String?
    /// ``finish()`` is running: a second tap does not ask again.
    @ObservationIgnored private var finishing = false

    static let maxEmail = 254
    static let maxCodeInput = 16

    public init(account: any AccountRepository, vault: any VaultRepository, inbox: SetupLinkInbox) {
        self.account = account
        self.vault = vault
        self.inbox = inbox
        state = OnboardingState(devHint: account.devHint)
        followers.add(follow(self, read: { $0.account.phase }, apply: { $0.route($1) }))
        followers.add(follow(self, read: { $0.inbox.link }, apply: { vm, raw in if let raw { vm.receiveLink(raw) } }))
        followers.add(follow(self, read: { $0.vault.finishMovePending }, apply: { $0.state.finishMovePending = $1 }))
    }

    deinit { followers.cancelAll() }

    // swiftlint:disable:next cyclomatic_complexity
    private func route(_ phase: AppPhase) {
        let s = state
        let codeSteps: Set<OnboardingStep> = [.welcome, .setupScan, .setupType]
        let vaultSteps: Set<OnboardingStep> = [.pinCreate, .pinConfirm, .password, .backup, .progress]
        let moving = s.step == .recover || s.step == .transferIn
        let accountSteps: Set<OnboardingStep> = [.vaultElsewhere, .confirmAccount]
        switch phase {
        // Nothing set up, or a replaced phone that erased itself: the welcome screen, nothing of before kept. A recovery
        // or a transfer started from the welcome screen runs while nothing is set up yet.
        case .signedOut:
            if !codeSteps.contains(s.step) && !moving {
                enrolled = false
                state = OnboardingState(devHint: account.devHint)
            }
        case .setup(let stage):
            switch stage {
            // A redeemed code: confirm the account first (also after a restart).
            case .newVault:
                if !vaultSteps.union(accountSteps).contains(s.step) && !moving {
                    state.step = .confirmAccount
                    state.busy = false
                    state.error = nil
                    state.errorCode = nil
                    if state.emailHint.isEmpty { state.emailHint = account.account?.emailHint ?? "" }
                }
            case .vaultElsewhere:
                if s.step != .progress && !moving { go(.vaultElsewhere) }
            case .recovering:
                if s.step != .recover {
                    state.step = .recover
                    state.busy = false
                    state.error = nil
                }
            case .needsCredential:
                if s.step != .progress && s.step != .backup {
                    enrolled = true
                    let askPin = vault.usesPhoneSecret
                    state.step = .password
                    state.credentialOnly = true
                    state.busy = false
                    state.askPin = askPin && state.pin.isEmpty
                }
            // A recovery or a transfer shows its own "your vault is connected to this phone now".
            case .finishing:
                if !moving {
                    go(.done)
                    state.movedIn = vault.movedIn
                    state.phoneSecret = vault.usesPhoneSecret
                }
            }
        default:
            break
        }
    }

    func go(_ step: OnboardingStep) {
        state.step = step
        state.busy = false
        state.error = nil
        state.errorCode = nil
    }

    /// Back within the flow; false when there is nowhere to go back to.
    @discardableResult
    public func back() -> Bool {
        let s = state
        guard let to = Self.backTarget(s) else { return false }
        if s.busy { return true }
        if to == .welcome || to == .setupScan { failedScan = nil }
        state.step = to
        state.error = nil
        switch to {
        case .pinCreate:
            state.pinConfirm = ""
            state.pinMismatch = false
        case .pinConfirm:
            state.password = ""
            state.passwordConfirm = ""
            state.passwordRule = .short
            state.passwordRefused = false
        default:
            state.scanRefusal = nil
            state.codeInvalid = false
        }
        return true
    }

    private static func backTarget(_ s: OnboardingState) -> OnboardingStep? {
        switch s.step {
        case .setupScan: .welcome
        case .setupType: .setupScan
        case .pinConfirm: .pinCreate
        case .password: s.credentialOnly ? nil : .pinConfirm
        case .backup: .password
        default: nil
        }
    }

    // MARK: - Tasks

    /// Starts [body] as one of this model's tasks.
    func launch(_ body: @escaping @MainActor () async -> Void) {
        let id = nextWork
        nextWork += 1
        work[id] = Task { [weak self] in
            await body()
            self?.work[id] = nil
        }
    }

    /// Marks the flow busy at once (a second tap or scan is ignored), then runs [block]; a failure is shown, and
    /// [onFailure] runs after it. [marksBusy] false: a background refresh that blocks nothing.
    func attempt(
        marksBusy: Bool = true,
        onFailure: @escaping @MainActor () -> Void = {},
        _ block: @escaping @MainActor () async throws -> Void
    ) {
        if marksBusy { state.busy = true }
        state.error = nil
        state.errorCode = nil
        launch { [self] in
            do {
                try await block()
                state.busy = false
            } catch let e as VaultFailure {
                state.busy = false
                state.error = e.kind
                state.errorCode = e.code
                onFailure()
            } catch {
                // Only a cancellation gets here: every repository failure is a VaultFailure.
                state.busy = false
                onFailure()
            }
        }
    }

    /// TEST ONLY: returns once the model's tasks and the reactions to the repositories' changes have run.
    func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            while let (id, task) = work.first {
                await task.value
                work[id] = nil
            }
        }
    }

    // MARK: - The welcome choices

    /// Welcome: set up a vault with the portal's setup code.
    public func start() {
        failedScan = nil
        state.step = .setupScan
        state.scanRefusal = nil
        state.error = nil
    }

    /// Welcome: "I lost my phone": the recovery (§11.11), with the portal's recovery QR.
    public func startRecovery() { go(.recover) }

    /// Welcome: "Move from my old phone": the direct transfer (§6.7.1).
    public func startTransfer() { go(.transferIn) }

    /// Vault elsewhere: recover it on this phone.
    public func recover() { go(.recover) }

    /// Vault elsewhere: move it here from the old phone.
    public func transfer() { go(.transferIn) }

    /// Leaves the recovery or the transfer: back where it was started from.
    public func leaveMove() {
        if case .setup = account.phase { go(.vaultElsewhere) } else { go(.welcome) }
        // A refresh that hangs must not hold the next screen busy; its failure is still shown.
        attempt(marksBusy: false) { [account] in try await account.refresh() }
    }

    /// After a recovery deleted the vault: a new vault needs a new setup code.
    public func newVaultAfterMove() { start() }

    // MARK: - The setup code (§11.12.1)

    public func typeCode() {
        failedScan = nil
        state.step = .setupType
        state.scanRefusal = nil
        state.codeInvalid = false
        state.error = nil
    }

    /// A QR the camera read: only this environment's setup QR is redeemed; nothing is sent anywhere else.
    public func scanned(_ text: String) {
        let s = state
        guard !s.busy, s.step == .setupScan else { return }
        if text == failedScan { return }
        failedScan = nil
        switch SetupCodes.parseScanned(text, api: account.apiOrigin) {
        case .secret(let secret):
            redeem(.secret(secret), scanned: text)
        case .otherEnvironment(let api):
            state.scanRefusal = .otherEnvironment
            state.otherApi = api
        case .notACode:
            state.scanRefusal = RecoveryCode.parseScanned(text) != nil ? .recoveryCode : .notACode
        }
    }

    /// The portal's same-device Universal Link: redeemed only while nothing is set up on this phone.
    private func receiveLink(_ raw: String) {
        inbox.consume()
        guard account.phase == .signedOut, !state.busy else { return }
        guard let secret = SetupCodes.parseLink(raw, api: account.apiOrigin) else {
            state.step = .setupScan
            state.scanRefusal = .notACode
            return
        }
        failedScan = nil
        state.step = .setupScan
        redeem(.secret(secret))
    }

    public func setEmail(_ v: String) {
        state.email = String(v.prefix(Self.maxEmail))
        state.emailInvalid = false
    }

    public func setCode(_ v: String) {
        state.codeInput = String(v.prefix(Self.maxCodeInput))
        state.codeInvalid = SetupCodes.hasForeignCharacter(v)
        state.error = nil
    }

    public func submitCode() {
        // The keyboard's Done reaches here while a redeem runs.
        guard !state.busy else { return }
        let s = state
        let email = s.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = SetupCodes.normalize(s.codeInput)
        let emailOk = EmailFormat.isPlausible(email)
        guard emailOk, let code else {
            state.emailInvalid = !emailOk
            state.codeInvalid = code == nil
            return
        }
        redeem(.typed(email: SetupCodes.normalizeEmail(email), code: code))
    }

    /// Redeems [code]; [scanned] is the QR text it came from, not redeemed again after a failure.
    private func redeem(_ code: SetupCodeInput, scanned: String? = nil) {
        guard !state.busy else { return }
        attempt(onFailure: { [weak self] in self?.failedScan = scanned }) { [self] in
            let hint = try await account.redeemSetupCode(code)
            state.emailHint = hint
            state.codeInput = ""
            state.scanRefusal = nil
            state.step = .confirmAccount
        }
    }

    /// The account is the member's: on to the vault PIN.
    public func confirmAccount() { go(.pinCreate) }

    /// "That is not my account" (or another code): the redeemed code is dropped; back to the welcome screen.
    public func useAnotherCode() {
        guard !state.busy else { return }
        state.busy = true
        state.error = nil
        state.errorCode = nil
        launch { [self] in
            do {
                try await account.forgetSetupCode()
            } catch {
                // As vettid-android: whatever the answer, the flow starts over.
            }
            enrolled = false
            state = OnboardingState(devHint: account.devHint)
        }
    }

    /// Vault elsewhere: try enrolling anyway (a provisional vault may be replaced; the enclave decides, §11.3).
    public func enrollAnyway() { go(.pinCreate) }

    // MARK: - Vault PIN

    public func setPin(_ v: String) {
        let pin = String(v.prefix(PinPolicy.maxLength))
        // The password step may ask for the PIN too (askPin): "Don't use your PIN as your password." follows it.
        if !state.passwordRefused && !state.password.isEmpty { state.passwordRule = PasswordRule.check(state.password, pin: pin) }
        state.pin = pin
        state.pinProblem = nil
    }

    public func submitPin() {
        if let p = PinPolicy.check(state.pin) {
            state.pinProblem = p
            return
        }
        state.step = .pinConfirm
        state.pinConfirm = ""
        state.pinMismatch = false
    }

    public func setPinConfirm(_ v: String) {
        state.pinConfirm = String(v.prefix(PinPolicy.maxLength))
        state.pinMismatch = false
    }

    public func submitPinConfirm() {
        guard state.pinConfirm == state.pin else {
            state.pinMismatch = true
            state.pinConfirm = ""
            return
        }
        state.step = .password
    }

    // MARK: - Credential password

    public func setPassword(_ v: String) {
        state.password = v
        state.passwordRule = PasswordRule.check(v, pin: state.pin)
        state.passwordRefused = false
        state.passwordMismatch = false
    }

    public func setPasswordConfirm(_ v: String) {
        state.passwordConfirm = v
        state.passwordMismatch = false
    }

    public func submitPassword() {
        let s = state
        if !s.credentialPinReady || !s.passwordRule.passes || s.passwordRefused { return }
        if s.passwordConfirm != s.password {
            state.passwordMismatch = true
        } else {
            state.step = .backup
        }
    }

    // MARK: - Backup (§3.5.6)

    public func setBackup(_ on: Bool) {
        state.backup = on
        if on { state.backupOffAcknowledged = false }
    }

    public func acknowledgeBackupOff(_ ack: Bool) { state.backupOffAcknowledged = ack }

    public func submitBackup() {
        guard state.canContinueBackup, !state.busy else { return }
        run()
    }

    // MARK: - Enrollment

    private func steps(credentialOnly: Bool) -> [EnrollStep] {
        credentialOnly ? [.createCredential, .backup, .confirm] : EnrollStep.allCases
    }

    private func mark(_ step: EnrollStep) {
        // A step that is not in the list leaves every step pending, as vettid-android's index -1 does.
        let idx = state.progress.firstIndex { $0.step == step } ?? -1
        for i in state.progress.indices {
            state.progress[i].state = i < idx ? .done : i == idx ? .active : .pending
        }
    }

    /// Runs (or resumes) enrollment and the credential steps.
    public func run() {
        guard !state.busy else { return }
        let s = state
        let credentialOnly = s.credentialOnly || enrolled
        state.step = .progress
        state.busy = true
        state.error = nil
        state.errorCode = nil
        state.progress = steps(credentialOnly: credentialOnly).map { ProgressEntry($0, .pending) }
        launch { [self] in
            do {
                if !enrolled {
                    try await vault.enroll(pin: s.pin) { self.mark($0) }
                    enrolled = true
                }
                // Release R (§11.14.9): the PIN goes with credential.create (sent only to a vault with a phone secret).
                try await vault.createCredential(password: s.password, backup: s.backup, pin: s.pin.isEmpty ? nil : s.pin) {
                    self.mark($0)
                }
                state.busy = false
                state.pin = ""
                state.pinConfirm = ""
                state.password = ""
                state.passwordConfirm = ""
                for i in state.progress.indices { state.progress[i].state = .done }
                if case .setup = account.phase { go(.done) }
            } catch let e as VaultFailure {
                failed(e)
            } catch {
                state.busy = false
            }
        }
    }

    private func failed(_ e: VaultFailure) {
        state.busy = false
        state.error = e.kind
        state.errorCode = e.code
        for i in state.progress.indices where state.progress[i].state == .active { state.progress[i].state = .failed }
        if e.kind == .vaultExists {
            state.step = .vaultElsewhere
            state.pin = ""
            state.pinConfirm = ""
        }
        // The vault refused the password (§11.14.7): back to the password, with its reason under the field.
        if e.kind == .weakPassword { refusedPassword(e) }
    }

    private func refusedPassword(_ e: VaultFailure) {
        // A reason this app does not know: the generic "This password is not strong enough." Either way the same
        // password cannot be sent again; changing it clears the refusal.
        state.step = .password
        state.credentialOnly = enrolled
        state.progress = []
        state.passwordRule = PasswordRule.fromVault(e.weakPasswordReason)
        state.passwordRefused = true
        state.error = nil
    }

    /// Leaves the progress screen after a failure, back to the PIN (before enrollment) or the password.
    public func editAfterFailure() {
        state.step = enrolled ? .password : .pinCreate
        state.credentialOnly = enrolled
        state.error = nil
        state.progress = []
    }

    /// Leaves onboarding; a failure is shown, and the member can try again.
    public func finish() {
        guard !finishing, !state.busy else { return }
        finishing = true
        attempt(onFailure: { [weak self] in self?.finishing = false }) { [vault] in try await vault.finishSetup() }
    }
}
