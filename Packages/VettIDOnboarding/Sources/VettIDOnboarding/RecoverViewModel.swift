import Foundation
import Observation
import VettIDAltChan
import VettIDData

/// Recovery on a new phone (VAULT-MESSAGING §11.11, §11.14.6), as vettid-vault's reference client runs it: the portal's QR
/// is claimed with this phone's app key (§11.11.7: no sign-in) and registered over the alternate channel with this phone's
/// device attestation; then the PIN and the password together open the recovery (``RecoveryOpenViewModel``, §11.14.6). The
/// code can be typed instead (0.25.0 §11.11.10): the 48 characters the portal shows carry a locator that stands for the
/// vault and the recovery at the claim, the code, and check characters this app verifies with its own member API origin
/// before it sends anything; after the claim it is the scanned path. A vault without a backup copy of its credential cannot
/// be recovered at all (0.16.0, `no_backup`): the app says so and links to the account site's start-over. Resumes where it
/// stopped after a restart (``MoveRepository/recoveryStage()``).
///
/// A registered recovery can be left: "Start over" on the open step, after a confirmation, makes this phone
/// forget its registration (``MoveRepository/abandonRecovery()``). The app has no call that cancels the recovery itself: the
/// spec gives that to the account site, the email link and an owner app's unlock (§11.11.4), so the recovery stays registered
/// until one of them or its expiry ends it. Mirrors vettid-android `RecoverViewModel` for release R (IOS-PLAN ID8: the
/// earlier recovery's PIN and password steps are not here).
@MainActor
@Observable
public final class RecoverViewModel: RecoverActions {
    public static let codeBad = "bad_code"
    public static let codeExpired = "expired"
    public static let codeEarly = "too_early"
    public static let codeAttestation = "attestation"
    public static let codeNone = "no_recovery"
    public static let codeUsed = "used"
    public static let codeNotAvailable = "not_available"
    /// (0.34.0) The release does not offer recovery (§11.10.9, §11.14.13).
    public static let codeNotOffered = "not_offered"
    public static let codeNoBackup = "no_backup"

    public private(set) var state: RecoverState

    @ObservationIgnored private let move: any MoveRepository
    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let account: any AccountRepository
    /// One second of the rate limit's countdown (a virtual clock in the tests).
    @ObservationIgnored private let tick: @Sendable () async throws -> Void
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private var retryTicker: Task<Void, Never>?
    @ObservationIgnored private var countedFor: String?
    /// The step the code steps return to: the intro, or for a phone that could not tell the text of the rule or the open step.
    @ObservationIgnored private var codeHome = RecoverStep.intro
    /// The open pane shows a lost-ok finish the member chose (``holdOpen(_:)``).
    @ObservationIgnored private var openHeld = false
    /// The last QR text that was refused or failed: the camera reads it again at once, and it is not sent again until the member
    /// acts (types, goes back, or scans again from the intro).
    @ObservationIgnored private var lastScanned: String?

    public init(
        move: any MoveRepository,
        vault: any VaultRepository,
        account: any AccountRepository,
        tick: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    ) {
        self.move = move
        self.vault = vault
        self.account = account
        self.tick = tick
        let origin = account.apiOrigin
        var trimmed = Substring(origin)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        state = RecoverState(startOverURL: String(trimmed) + RecoverState.startOverPath, accountHost: Self.host(of: origin))
        work.launch { [weak self] in await self?.resume() }
    }

    deinit {
        work.cancelAll()
        retryTicker?.cancel()
    }

    /// Where a recovery on this phone stands: the code, or (registered) the open.
    private func resume() async {
        let stage: RecoveryStage
        do {
            stage = try await move.recoveryStage()
        } catch {
            // Not "no recovery": a registered recovery must not be offered a new code by a read that failed.
            let e = Self.failure(of: error)
            state.step = .stageFailed
            state.error = e.kind
            state.errorCode = e.code
            return
        }
        state.error = nil
        state.errorCode = nil
        state.emailHint = account.account?.emailHint ?? ""
        // IOS-PLAN 0.1.38 §4.9: a phone that could not tell is told (a read that fails decides nothing).
        // A read that fails or is cancelled falls back to what the phone keeps, and that to nothing.
        let kept = try? await move.couldNotTellStage()
        let rule = (try? await move.checkCouldNotTell()) ?? kept ?? .none
        state.couldNotTell = rule
        if rule == .newCode {
            state.step = .couldNotTell
            return
        }
        switch stage {
        case .code: state.step = .intro
        // Release R has one screen for the PIN and the password (``RecoverStep/open``).
        case .pin, .password: state.step = .open
        }
    }

    public func checkEnded() {
        guard !state.busy, [.open, .couldNotTell].contains(state.step) else { return }
        work.launch { [weak self, move] in
            // An error (a cancellation included) is no answer: nothing changes.
            guard let rule = try? await move.checkCouldNotTell() else { return }
            guard let self, !state.busy else { return }
            state.couldNotTell = rule
            if rule == .newCode, state.step == .open, !openHeld {
                state.step = .couldNotTell
            } else if rule != .newCode, state.step == .couldNotTell {
                state.step = .open
            }
        }
    }

    public func holdOpen(_ held: Bool) { openHeld = held }

    public func useNewCode() {
        guard !state.busy, state.step == .open else { return }
        work.launch { [weak self, move] in
            // A read that fails keeps what this flow knows.
            let rule = try? await move.couldNotTellStage()
            guard let self, !state.busy, state.step == .open else { return }
            if let rule { state.couldNotTell = rule }
            scan()
        }
    }

    public func retryStage() {
        guard state.step == .stageFailed else { return }
        state.step = .loading
        state.error = nil
        state.errorCode = nil
        work.launch { [weak self] in await self?.resume() }
    }

    // MARK: - The code

    /// The code's steps are entered from the intro and from each other, never over a failed or running read of the stage; for a
    /// phone that could not tell, also from the rule's text and from the open step once a new code registers the new identity
    /// again (IOS-PLAN 0.1.38 §4.9).
    private var codeEntry: Bool {
        [.intro, .couldNotTell, .scan, .type].contains(state.step) || (state.step == .open && state.newCodeAllowed)
    }

    /// The step the code steps go back to, when the code steps are entered from it.
    private func noteCodeHome() {
        if [.intro, .couldNotTell, .open].contains(state.step) { codeHome = state.step }
    }

    public func scan() {
        if state.busy || !codeEntry { return }
        noteCodeHome()
        lastScanned = nil
        state.step = .scan
        state.refusal = nil
        state.error = nil
        state.errorCode = nil
        state.typedProblem = nil
    }

    public func type() {
        if state.busy || !codeEntry { return }
        noteCodeHome()
        lastScanned = nil
        state.step = .type
        state.refusal = nil
        state.error = nil
        state.errorCode = nil
        state.typedProblem = nil
    }

    /// Back within the flow; false when the member leaves it (the onboarding flow takes over).
    @discardableResult
    public func back() -> Bool {
        if state.busy { return true }
        lastScanned = nil
        switch state.step {
        case .scan, .type:
            state.step = codeHome
            state.refusal = nil
            state.error = nil
            state.errorCode = nil
            state.typedProblem = nil
            return true
        default:
            return false
        }
    }

    /// A QR the camera read: only a recovery QR of this app's environment is claimed (its `api` compared exactly with the
    /// app's own member API origin, never contacted, §11.11.2).
    public func scanned(_ text: String) {
        guard !state.busy, state.step == .scan, text != lastScanned else { return }
        lastScanned = text
        guard let code = RecoveryCode.parseScanned(text) else {
            state.refusal = .notACode
            return
        }
        guard let api = code.api else {
            state.refusal = .noApi
            return
        }
        guard Self.trimmingSlashes(api) == account.apiOrigin else {
            state.refusal = .otherEnvironment
            state.otherApi = api
            return
        }
        register(countKey: code.recoveryID) { [move] in try await move.registerRecovery(code) }
    }

    /// The typed code is dropped, whatever the step and whatever runs: the app left the foreground, the iPhone locked, or the
    /// screen goes (IOS-PLAN §6.3).
    public func forgetTyped() {
        state.typed = ""
        state.typedProblem = nil
        state.typedGroup = 0
    }

    /// The typed field (§11.11.10 step 1): separators dropped, upper case, I and L read as 1 and O as 0; a `U` or any other
    /// character is refused in the field (dropped and named, never guessed); a forty-ninth is ignored.
    public func setTyped(_ v: String) {
        guard !state.busy, state.step == .type else { return }
        let input = RecoveryCodes.typedInput(v)
        let pasted = input.text.count - state.typed.count > 1
        let problem: TypedProblem? = switch input.refused {
        case .letterU?: .letterU
        case .other?: .otherCharacter
        // The bare code of an account page from before MEMBER-API 2.4.0, pasted whole.
        case nil where pasted && input.text.count == RecoveryCodes.length: .shortCode
        case nil: nil
        }
        state.typed = input.text
        state.typedProblem = problem
        state.typedGroup = input.refusedGroup
    }

    /// **Continue** (§11.11.10 step 2): the check characters are recomputed with this app's own member API origin. On a
    /// mismatch nothing is sent and nothing is counted; the entry stays for correction.
    public func submitTyped() {
        guard !state.busy, state.step == .type else { return }
        let problem: TypedProblem
        switch TypedRecoveryCode.parse(state.typed, api: account.apiOrigin) {
        case .ok(let code):
            state.typedProblem = nil
            register(countKey: code.locator) { [move] in try await move.registerTypedRecovery(code) }
            return
        case .badCheck: problem = .badCheck
        case .bareCode: problem = .shortCode
        case .notTyped: problem = .incomplete
        }
        state.typedProblem = problem
        state.typedGroup = 0
        state.refusal = nil
        state.error = nil
        state.errorCode = nil
    }

    /// The claim and the register, however the code was read. Wrong codes are counted per recovery: the one the answer names
    /// (a typed code's claim), else [countKey] (a scanned QR's `recovery_id`).
    private func register(countKey: String, _ attempt: @escaping @Sendable () async throws -> RecoveryRegistration) {
        let from = state.step
        retryTicker?.cancel()
        state.step = .registering
        state.busy = true
        state.refusal = nil
        state.error = nil
        state.errorCode = nil
        state.retrySeconds = 0
        work.launch { [weak self] in
            do {
                let r = try await attempt()
                guard let self else { return }
                switch r {
                case .registered(let hint):
                    state.busy = false
                    state.emailHint = hint
                    state.typed = ""
                    state.typedProblem = nil
                    state.step = .open
                case .refused(let code, let recoveryID):
                    refused(from: from, recoveryID: recoveryID ?? countKey, code: code)
                }
            } catch {
                guard let self else { return }
                let e = Self.failure(of: error)
                state.step = from
                state.busy = false
                state.error = e.kind
                state.errorCode = e.code
                if e.kind == .rateLimited { startRetryWait(e.retryAfterSeconds) }
            }
        }
    }

    /// Counts down a `429`'s wait, for the text only: the member may try again at any time (another network is not limited).
    private func startRetryWait(_ seconds: Int64) {
        guard seconds > 0 else { return }
        retryTicker?.cancel()
        state.retrySeconds = seconds
        let tick = tick
        retryTicker = Task { @MainActor [weak self] in
            while (self?.state.retrySeconds ?? 0) > 0 {
                do {
                    try await tick()
                } catch {
                    return
                }
                guard let self else { return }
                state.retrySeconds = max(state.retrySeconds - 1, 0)
            }
        }
    }

    // One branch per §11.11.3 code.
    private func refused(from: RecoverStep, recoveryID: String, code: String) { // swiftlint:disable:this cyclomatic_complexity
        var refusal: CodeRefusal
        switch code {
        // IOS-PLAN 0.1.38 §4.9: the claim says this phone's key is the vault's app key (`409 key_in_use`), or the earlier open's
        // slot was read after all and was `ok`: the PIN finishes it, and nothing more is registered.
        case VaultManager.codeKeyInUse, VaultManager.codeRecoveryOpenSent:
            state.step = .open
            state.busy = false
            state.refusal = nil
            state.typed = ""
            state.typedProblem = nil
            state.couldNotTell = .finishWithPin
            return
        case Self.codeBad: refusal = .badCode
        case Self.codeExpired: refusal = .expired
        case Self.codeEarly: refusal = .tooEarly
        case Self.codeAttestation: refusal = .attestation
        case Self.codeNone, Self.codeUsed: refusal = .gone
        case Self.codeNotAvailable: refusal = .notAvailable
        case Self.codeNotOffered: refusal = .notOffered
        case VaultManager.codeOtherVault: refusal = .otherVault
        case Self.codeNoBackup:
            state.step = .noBackup
            state.busy = false
            state.refusal = nil
            state.typed = ""
            state.typedProblem = nil
            noBackup()
            return
        default: refusal = .retry
        }
        var wrong = state.wrongCodes
        if refusal == .badCode {
            if countedFor != recoveryID { wrong = 0 }
            countedFor = recoveryID
            wrong += 1
            if wrong >= RecoverState.maxWrongCodes { refusal = .voided }
        }
        // The typed characters stay for correction, and go when the recovery has ended (ANDROID-PLAN 0.1.33).
        let ended = refusal == .voided || code == Self.codeExpired || code == Self.codeUsed
        state.step = from
        state.busy = false
        state.refusal = refusal
        state.errorCode = nil
        state.wrongCodes = wrong
        if ended { state.typed = "" }
        state.typedProblem = nil
    }

    /// 0.16.0: nothing more to do with this vault on this phone; forget the registration (quietly).
    private func noBackup() {
        work.launch { [move] in try? await move.abandonRecovery() }
    }

    /// From a code step whose refusal is guidance (``RecoverState/guidance``): to the open step, where the recovery goes on
    /// ("finish with your PIN", another open) and where "Start over" is; the guidance stays for the open step to say. A refusal
    /// that is not guidance stays where it is.
    public func showOpen() {
        guard !state.busy, codeEntry, state.guidance != nil else { return }
        state.step = .open
        state.refusal = nil
        forgetTyped()
    }

    // MARK: - Leaving a registered recovery

    public func askStartOver() {
        guard !state.busy, state.step == .open else { return }
        state.confirmStartOver = true
    }

    public func dismissStartOver() { state.confirmStartOver = false }

    /// This phone forgets the recovery (its registration, its keys for it, the PIN or password typed so far) and is back at
    /// the start of the flow. Nothing is sent: only the account site, the email link, an owner app's unlock or the expiry end
    /// the recovery itself (§11.11.4).
    public func confirmStartOver() {
        guard !state.busy, state.confirmStartOver else { return }
        let (url, host) = (state.startOverURL, state.accountHost)
        state.busy = true
        state.confirmStartOver = false
        state.error = nil
        state.errorCode = nil
        work.launch { [weak self, move] in
            do {
                try await move.abandonRecovery()
                guard let self else { return }
                countedFor = nil
                state = RecoverState(step: .intro, startOverURL: url, accountHost: host)
            } catch {
                guard let self else { return }
                let e = Self.failure(of: error)
                state.busy = false
                state.error = e.kind
                state.errorCode = e.code
            }
        }
    }

    public func finish() {
        work.launch { [vault] in try? await vault.finishSetup() }
    }

    // MARK: - Helpers

    /// A failure as a ``VaultFailure``: any other error is ``FailureKind/other``, so the screen never freezes in a step.
    private static func failure(of error: any Error) -> VaultFailure { (error as? VaultFailure) ?? VaultFailure(.other) }

    static func trimmingSlashes(_ s: String) -> String {
        var t = Substring(s)
        while t.hasSuffix("/") { t = t.dropLast() }
        return String(t)
    }

    /// The host of [origin] (`account.vettid.org`), or [origin] itself when it is not a URL.
    static func host(of origin: String) -> String { URL(string: origin)?.host ?? origin }

    /// TEST ONLY: returns once the work started so far has run as far as it can without a wait of the repository's or the
    /// clock's.
    func settle() async {
        for _ in 0..<100 { await Task.yield() }
        await work.settle()
    }
}
