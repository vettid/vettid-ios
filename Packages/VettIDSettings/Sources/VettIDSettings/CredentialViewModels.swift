import Foundation
import Observation
import VettIDData

/// A one-off confirmation shown after an action. Mirrors vettid-android `CredentialNotice` (the rotation's and the
/// password change's come with their screens' notices on Android too).
public enum CredentialNotice: Equatable, Sendable { case backupOn, backupOff }

/// The Credential screen's state. Mirrors vettid-android `CredentialUiState`; the unlock window's password is the
/// dialog's, never printed.
public struct CredentialState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var loading = true
    public var status: CredentialStatus?
    public var alarm: CredentialAlarm?
    public var windowUntil: Date?
    public var busy = false
    public var error: FailureKind?
    public var notice: CredentialNotice?
    /// The unlock window's password dialog.
    public var windowDialog = false
    public var windowPassword = ""
    public var windowError: FailureKind?

    public init(
        loading: Bool = true,
        status: CredentialStatus? = nil,
        alarm: CredentialAlarm? = nil,
        windowUntil: Date? = nil,
        error: FailureKind? = nil,
        notice: CredentialNotice? = nil
    ) {
        self.loading = loading
        self.status = status
        self.alarm = alarm
        self.windowUntil = windowUntil
        self.error = error
        self.notice = notice
    }

    public var description: String {
        "CredentialState(loading: \(loading), busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"), alarm: \(alarm?.state ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The Credential screen (ANDROID-PLAN §4): status, the unlock window (VAULT-MESSAGING §3.5.3), the window's length, the
/// sealed backup (§3.5.6), and the clone alarm (§3.5.9). Mirrors vettid-android `CredentialViewModel`.
@MainActor
@Observable
public final class CredentialViewModel {
    /// The window lengths offered (seconds). Mirrors vettid-android `TTL_OPTIONS`.
    public static let ttlOptions = [30, 60, 300, 900, 3_600]

    private var local = CredentialState()

    @ObservationIgnored private let repo: any CredentialRepository
    @ObservationIgnored private let work = Work()

    public init(repo: any CredentialRepository) {
        self.repo = repo
        refresh()
    }

    deinit { work.cancelAll() }

    /// The state now: the alarm and the window as the repository has them (observed through it), with this screen's own.
    public var state: CredentialState {
        var s = local
        s.alarm = repo.alarm
        s.windowUntil = repo.unlockWindow
        return s
    }

    public func refresh() {
        local.loading = local.status == nil
        local.error = nil
        let repo = repo
        work.launch { [weak self] in
            do {
                let st = try await repo.status()
                self?.local.loading = false
                self?.local.status = st
            } catch {
                self?.local.loading = false
                self?.local.error = failureKind(error)
            }
        }
    }

    public func showWindowDialog(_ show: Bool) {
        local.windowDialog = show
        local.windowPassword = ""
        local.windowError = nil
    }

    public func setWindowPassword(_ v: String) {
        local.windowPassword = v
        local.windowError = nil
    }

    public func openWindow() {
        let pw = local.windowPassword
        guard !pw.isEmpty else { return }
        local.busy = true
        local.windowError = nil
        let repo = repo
        work.launch { [weak self] in
            do {
                try await repo.openUnlockWindow(password: pw)
                self?.local.busy = false
                self?.local.windowDialog = false
                self?.local.windowPassword = ""
            } catch {
                self?.local.busy = false
                self?.local.windowError = failureKind(error)
                self?.local.windowPassword = ""
            }
        }
    }

    public func closeWindow() {
        let repo = repo
        act { try await repo.closeUnlockWindow() }
    }

    public func setTtl(_ seconds: Int) {
        let repo = repo
        act { [weak self] in
            try await repo.setUnlockTtl(seconds: seconds)
            self?.local.status?.unlockTtlSeconds = seconds
        }
    }

    /// Turning the backup off is confirmed in the UI first (§3.5.6: warn and ask).
    public func setBackup(_ on: Bool) {
        let repo = repo
        act { [weak self] in
            try await repo.setBackup(on)
            self?.local.status?.backup = on
            self?.local.notice = on ? .backupOn : .backupOff
        }
    }

    public func dismissNotice() {
        local.notice = nil
        local.error = nil
    }

    private func act(_ body: @escaping @MainActor () async throws -> Void) {
        local.busy = true
        local.error = nil
        work.launch { [weak self] in
            do {
                try await body()
                self?.local.busy = false
            } catch {
                self?.local.busy = false
                self?.local.error = failureKind(error)
            }
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}

/// The password change's state. The PIN is here from the keypad's hand-over until the answer; the passwords until the
/// answer. Never printed. Mirrors vettid-android `ChangePasswordUiState` on a vault of release R (its new rules; the earlier
/// meter is not the iPhone app's, IOS-PLAN ID8).
public struct ChangePasswordState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let minPin = 6

    /// (Release R, VAULT-MESSAGING §11.14.9) The vault has a phone secret: `credential.password.change` carries the PIN,
    /// which the vault verifies, so the screen asks for it.
    public var askPin = false
    public var pin = ""
    public var current = ""
    public var password = ""
    public var confirm = ""
    /// The new password's rule as the member types (ANDROID-PLAN "Passwords").
    public var rule: PasswordRule = .short
    /// [rule] is the vault's verdict (`weak_password{reason}`).
    public var refused = false
    public var mismatch = false
    public var same = false
    public var busy = false
    public var error: FailureKind?
    public var done = false
    /// The last change got no answer: the password may be the new one already (chosen; not in the spec).
    public var mayHaveChanged = false

    public init(askPin: Bool = false) { self.askPin = askPin }

    /// The PIN, when it is asked ([askPin]): digits, at least 6 (the keypad's count, before it is handed over).
    public func pinReady(typed: Int) -> Bool { !askPin || max(typed, pin.count) >= Self.minPin }

    /// Every field the change needs is filled in.
    public func canSubmit(pinTyped: Int) -> Bool {
        !current.isEmpty && !password.isEmpty && !confirm.isEmpty && pinReady(typed: pinTyped) && !refused && rule.passes
    }

    public var description: String {
        "ChangePasswordState(askPin: \(askPin), busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"), done: \(done))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// `credential.password.change` (VAULT-MESSAGING §10.6): the current password and a new one under the password rules of
/// release R; with a phone secret also the PIN (§11.14.9). Mirrors vettid-android `ChangePasswordViewModel`.
@MainActor
@Observable
public final class ChangePasswordViewModel {
    public private(set) var state: ChangePasswordState

    @ObservationIgnored private let repo: any CredentialRepository
    @ObservationIgnored private let work = Work()

    public init(repo: any CredentialRepository, vault: any VaultRepository) {
        self.repo = repo
        state = ChangePasswordState(askPin: vault.usesPhoneSecret)
    }

    deinit { work.cancelAll() }

    /// The PIN from the keypad, handed over once, right before ``submit()``; "Don't use your PIN as your password."
    /// follows it.
    public func setPin(_ v: String) {
        state.pin = String(v.filter { $0.isASCII && $0.isNumber }.prefix(PinPolicy.maxLength))
        if !state.refused && !state.password.isEmpty { state.rule = PasswordRule.check(state.password, pin: state.pin) }
        state.error = nil
    }

    public func setCurrent(_ v: String) {
        state.current = v
        state.error = nil
    }

    public func setPassword(_ v: String) {
        state.password = v
        state.rule = PasswordRule.check(v, pin: state.askPin && !state.pin.isEmpty ? state.pin : nil)
        state.refused = false
        state.mismatch = false
        state.same = false
    }

    public func setConfirm(_ v: String) {
        state.confirm = v
        state.mismatch = false
    }

    /// Leaving the screen, or the app leaving the foreground: nothing typed stays. A change on its way stays busy.
    public func forgetSecrets() {
        guard !state.done else { return }
        let busy = state.busy
        state = ChangePasswordState(askPin: state.askPin)
        state.busy = busy
    }

    public func submit() {
        let s = state
        guard !s.current.isEmpty, s.pinReady(typed: 0) else {
            state.pin = ""
            return
        }
        guard !s.refused, s.rule.passes else {
            state.pin = ""
            return
        }
        if s.password == s.current {
            state.same = true
            state.pin = ""
        } else if s.confirm != s.password {
            state.mismatch = true
            state.pin = ""
        } else {
            send(s)
        }
    }

    private func send(_ s: ChangePasswordState) {
        state.busy = true
        state.error = nil
        state.mayHaveChanged = false
        let repo = repo
        work.launch { [weak self] in
            var failure: VaultFailure?
            do {
                try await repo.changePassword(s.current, newPassword: s.password, pin: s.askPin ? s.pin : nil)
            } catch {
                failure = error as? VaultFailure ?? VaultFailure(.other)
            }
            guard let self else { return }
            guard let failure else {
                state = ChangePasswordState(askPin: s.askPin)
                state.done = true
                return
            }
            // weak_password (§11.14.7): its reason under the new password, in the same words as the app's.
            state.busy = false
            state.current = ""
            state.pin = ""
            state.mayHaveChanged = failure.code == VaultManager.codeChangeUnanswered
            if failure.kind == .weakPassword {
                state.rule = PasswordRule.fromVault(failure.weakPasswordReason)
                state.refused = true
                state.error = nil
            } else {
                state.error = failure.kind
            }
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
