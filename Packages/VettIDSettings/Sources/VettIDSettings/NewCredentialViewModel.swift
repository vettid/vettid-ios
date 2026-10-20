import Foundation
import Observation
import VettIDData

/// The new credential's state. The PIN (from the keypad, handed over with the first press) and the passwords live here
/// only until the answer, and are dropped when the app leaves the foreground. Never printed. Mirrors vettid-android
/// `NewCredentialUiState` on a vault of release R (its password rules; the earlier meter is not the iPhone app's, IOS-PLAN
/// ID8).
public struct NewCredentialState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let minPin = PinPolicy.minLength

    public var pin = ""
    public var current = ""
    public var password = ""
    public var confirm = ""
    /// The new password's rule as the member types (ANDROID-PLAN "Passwords").
    public var rule: PasswordRule = .short
    /// [rule] is the vault's verdict (`weak_password{reason}`).
    public var refused = false
    public var mismatch = false
    /// The member read that every critical item is destroyed.
    public var acknowledged = false
    /// The final confirmation is shown.
    public var confirming = false
    public var busy = false
    public var error: FailureKind?
    public var done = false
    /// (VAULT-MESSAGING 0.48.0 §11.14.9 "A lost answer to `credential.reset`") The reset got no answer and is being
    /// decided (``ChangeCheck/Status/checking``, ``ChangeCheck/Status/unreachable``), was decided as not applied
    /// (``ChangeCheck/Status/notApplied``), or its check ended without a decision (``ChangeCheck/Status/ended``). No
    /// failure is shown meanwhile.
    public var check: ChangeCheck.Status?

    public init(done: Bool = false) { self.done = done }

    /// Every entry is there, with [pinTyped] digits on the keypad (the PIN is handed over with the first press).
    public func filled(pinTyped: Int) -> Bool {
        max(pinTyped, pin.count) >= Self.minPin && !current.isEmpty && !password.isEmpty && !confirm.isEmpty && acknowledged
            && !refused && rule.passes
    }

    public var description: String {
        "NewCredentialState(busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"), confirming: \(confirming), done: \(done))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A new credential (VAULT-MESSAGING §3.5.5, `credential.reset`): the PIN, the current password and a new one, an
/// acknowledgement, then a final confirmation. The old credential and every critical item are destroyed. A wrong PIN or
/// password counts as a failed owner check (§3.6.1). A lost answer is decided, as a password change's is (0.48.0
/// §11.14.9 "A lost answer to `credential.reset`"): the screen says it is checking and shows the decision. Mirrors
/// vettid-android `NewCredentialViewModel`.
@MainActor
@Observable
public final class NewCredentialViewModel {
    public private(set) var state = NewCredentialState()

    @ObservationIgnored private let repo: any CredentialRepository
    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let followers = TaskBag()

    public init(repo: any CredentialRepository, vault: any VaultRepository) {
        self.repo = repo
        self.vault = vault
        followers.add(follow(self, read: { $0.vault.changeCheck }, apply: { $0.decided($1) }))
    }

    deinit {
        work.cancelAll()
        followers.cancelAll()
    }

    /// The decision of a reset whose answer was lost, as it arrives: applied is the usual success; not applied and an
    /// ended check are said on the form, with nothing kept for a retry that sends the secrets again; a refusal is shown as
    /// it is. A decision shown here is not shown again; one this screen did not wait for is the shell's
    /// (``ChangeCheckNotice``).
    private func decided(_ c: ChangeCheck?) {
        guard let c, c.type == .reset, !state.busy else { return }
        if !c.undecided, state.check != .checking, state.check != .unreachable { return }
        switch c.status {
        case .checking, .unreachable:
            state.check = c.status
            vault.waitForChangeCheck(self)
            return
        case .applied:
            state = NewCredentialState(done: true)
        case .notApplied, .ended, .notHolder:
            state = NewCredentialState()
            state.check = c.status
        case .refused(let kind, _):
            state.check = nil
            refused(VaultFailure(kind))
        }
        vault.waitForChangeCheck(nil)
        vault.acknowledgeChangeCheck()
    }

    /// The PIN from the keypad, handed over once with the first press; "Don't use your PIN as your password." follows it.
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
        state.rule = PasswordRule.check(v, pin: state.pin.isEmpty ? nil : state.pin)
        state.refused = false
        state.mismatch = false
    }

    public func setConfirm(_ v: String) {
        state.confirm = v
        state.mismatch = false
    }

    public func setAcknowledged(_ v: Bool) { state.acknowledged = v }

    /// First press: checks the form, then asks for the final confirmation.
    public func submit() {
        let s = state
        guard s.filled(pinTyped: 0), !s.busy else {
            state.pin = ""
            return
        }
        if s.confirm != s.password {
            state.mismatch = true
            state.pin = ""
        } else {
            state.confirming = true
        }
    }

    /// The final confirmation was cancelled. The PIN goes with it: the keypad shows none (as Delete vault; chosen, not in
    /// the spec, where vettid-android's field keeps it).
    public func cancelConfirm() {
        guard state.confirming else { return }
        state.confirming = false
        state.pin = ""
    }

    public func confirm() {
        let s = state
        guard s.confirming, s.filled(pinTyped: 0), !s.busy else { return }
        state.confirming = false
        state.busy = true
        state.error = nil
        state.check = nil
        let repo = repo
        work.launch { [weak self] in
            do {
                try await repo.newCredential(pin: s.pin, password: s.current, newPassword: s.password)
                self?.state = NewCredentialState(done: true)
                self?.vault.acknowledgeChangeCheck()
            } catch {
                self?.failed(error)
            }
        }
    }

    /// The reset's failure: while it is undecided no failure is shown (§11.14.9 step 2); decided not applied, or ended
    /// without a decision, nothing typed is kept (no retry that sends the secrets again); otherwise its refusal.
    private func failed(_ error: any Error) {
        let failure = error as? VaultFailure ?? VaultFailure(.other)
        let check = vault.changeCheck.flatMap { $0.type == .reset ? $0.status : nil }
        if let check, check == .checking || check == .unreachable, failure.kind == .changeUnresolved {
            state = NewCredentialState()
            state.check = check
            vault.waitForChangeCheck(self)
            return
        }
        if failure.code == VaultManager.codeChangeNotApplied || check == .ended || check == .notHolder {
            state = NewCredentialState()
            state.check = failure.code == VaultManager.codeChangeNotApplied ? .notApplied : check
        } else {
            refused(error)
        }
        vault.acknowledgeChangeCheck()
    }

    /// The PIN and the current password are not kept after an answer. `weak_password` (§11.14.7): its reason under the
    /// new password, in the same words as the app's.
    private func refused(_ error: any Error) {
        state.busy = false
        state.check = nil
        state.pin = ""
        state.current = ""
        let kind = failureKind(error)
        if kind == .weakPassword {
            state.rule = PasswordRule.fromVault((error as? VaultFailure)?.weakPasswordReason)
            state.refused = true
            state.error = nil
        } else {
            state.error = kind
        }
    }

    /// Leaving the screen, or the app leaving the foreground or the iPhone locking (IOS-PLAN §6.3): nothing typed stays,
    /// and the final confirmation goes with it. A reset on its way stays busy.
    public func forgetSecrets() {
        guard !state.done else { return }
        state.pin = ""
        state.current = ""
        state.password = ""
        state.confirm = ""
        state.confirming = false
        state.rule = .short
        state.refused = false
        state.mismatch = false
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
