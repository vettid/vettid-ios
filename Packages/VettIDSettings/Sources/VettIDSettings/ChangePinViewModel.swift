import Foundation
import Observation
import VettIDData

/// Which PIN the keypad takes now. On the iPhone the three PINs are typed one after the other on the in-app keypad
/// (IOS-PLAN §6.5), where vettid-android shows three fields on one screen; the credential password goes with the
/// confirmation (chosen; not in the spec).
public enum ChangePinStep: Equatable, Sendable {
    case current
    case new
    /// The new PIN again, and the credential password (release R).
    case confirm
}

/// The PIN change's state. The PINs are here from their keypad's "Continue" until the answer, the password until the
/// answer: dropped after it, and on leaving. Never printed: the description names no secret. Mirrors vettid-android
/// `ChangePinUiState`, with the step of the iPhone's keypad.
public struct ChangePinState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var step: ChangePinStep = .current
    public var current = ""
    public var pin = ""
    public var confirm = ""
    public var problem: PinPolicy.Problem?
    public var mismatch = false
    public var same = false
    public var busy = false
    public var error: FailureKind?
    public var done = false
    /// (Release R, VAULT-MESSAGING §11.14.9) `pin.change` is a credential operation: the password too, and the phone's next
    /// secret. Its answer gives the recovery 10 new attempts.
    public var withPassword = false
    public var password = ""
    /// Opened from a notice about recovery attempts ("if that was not you"): the screen says first that changing only the
    /// PIN gives whoever is guessing ten new tries at the same password (ANDROID-PLAN "Change PIN").
    public var fromAttempts = false
    /// (VAULT-MESSAGING §11.14.9 "A lost answer") The last change got no answer and is being decided
    /// (``ChangeCheck/Status/checking``, ``ChangeCheck/Status/unreachable``), or was decided as not applied
    /// (``ChangeCheck/Status/notApplied``). No failure is shown meanwhile, and the new PIN is kept.
    public var check: ChangeCheck.Status?

    public init(withPassword: Bool = false, fromAttempts: Bool = false) {
        self.withPassword = withPassword
        self.fromAttempts = fromAttempts
    }

    public var description: String {
        "ChangePinState(step: \(step), busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"), done: \(done), "
            + "withPassword: \(withPassword))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// `pin.change` (VAULT-MESSAGING §10.6; release R §11.14.9 with the password and the phone's next secret): the current
/// PIN, the new one checked by the PIN rules and different from it, the new one again, and on a vault of release R the
/// credential password. Mirrors vettid-android `ChangePinViewModel`; its one submit is split into the iPhone's keypad
/// steps (``next()``), with the same checks in the same order.
@MainActor
@Observable
public final class ChangePinViewModel {
    public private(set) var state: ChangePinState

    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let followers = TaskBag()

    public init(vault: any VaultRepository, fromAttempts: Bool = false) {
        self.vault = vault
        state = ChangePinState(withPassword: vault.usesPhoneSecret, fromAttempts: fromAttempts)
        followers.add(follow(self, read: { $0.vault.changeCheck }, apply: { $0.decided($1) }))
    }

    deinit {
        work.cancelAll()
        followers.cancelAll()
    }

    /// The decision of a PIN change whose answer was lost (§11.14.9 "A lost answer"), as it arrives: applied is the
    /// usual success; not applied keeps the new PIN for the next attempt; a refusal is shown as it is, with the entry
    /// that was wrong cleared. A decision shown here is not shown again; one this screen did not wait for is the shell's
    /// (``ChangeCheckNotice``).
    private func decided(_ c: ChangeCheck?) {
        guard let c, c.type == .pin, !state.busy else { return }
        if !c.undecided, state.check != .checking, state.check != .unreachable {
            // Not this screen's wait (an earlier one, the screen closed meanwhile): the shell's notice tells it.
            return
        }
        switch c.status {
        case .checking, .unreachable:
            state.check = c.status
            vault.waitForChangeCheck(self)
            return
        case .applied:
            state = ChangePinState(withPassword: state.withPassword)
            state.done = true
        case .notApplied:
            state.check = .notApplied
        case .refused(let kind, _):
            state.check = nil
            failed(kind, kept: state)
        case .ended:
            state.check = nil
            state.error = .other
        }
        vault.waitForChangeCheck(nil)
        vault.acknowledgeChangeCheck()
    }

    private static func digits(_ v: String) -> String { String(v.filter { $0.isASCII && $0.isNumber }.prefix(PinPolicy.maxLength)) }

    /// The current PIN from the keypad, handed over once.
    public func setCurrent(_ v: String) {
        state.current = Self.digits(v)
        state.error = nil
    }

    /// The new PIN from the keypad, handed over once.
    public func setPin(_ v: String) {
        state.pin = Self.digits(v)
        state.problem = nil
        state.same = false
    }

    /// The new PIN again from the keypad, handed over once.
    public func setConfirm(_ v: String) {
        state.confirm = Self.digits(v)
        state.mismatch = false
    }

    public func setPassword(_ v: String) {
        state.password = v
        state.error = nil
    }

    /// The keypad's "Continue": from the current PIN to the new one, then (the rules and "different" checked) to its
    /// confirmation.
    public func next() {
        switch state.step {
        case .current:
            guard !state.current.isEmpty else { return }
            // After a change that was not applied, or a wrong PIN, the new PIN kept goes again: it is only confirmed.
            state.step = state.pin.isEmpty ? .new : .confirm
        case .new:
            if let p = PinPolicy.check(state.pin) {
                state.problem = p
                state.pin = ""
            } else if state.pin == state.current {
                state.same = true
                state.pin = ""
            } else {
                state.step = .confirm
            }
        case .confirm:
            submit()
        }
    }

    /// Back one keypad step; what that step had is typed again.
    public func back() {
        switch state.step {
        case .current: break
        case .new:
            state.step = .current
            state.current = ""
            state.pin = ""
        case .confirm:
            state.step = .new
            state.pin = ""
            state.confirm = ""
            state.password = ""
            state.mismatch = false
        }
    }

    /// Leaving the screen, or the app leaving the foreground: nothing typed stays. A change on its way stays busy (its
    /// answer still comes), so it cannot be sent twice.
    public func forgetSecrets() {
        guard !state.done else { return }
        if state.busy {
            state.current = ""
            state.pin = ""
            state.confirm = ""
            state.password = ""
            return
        }
        let check = state.check
        state = ChangePinState(withPassword: state.withPassword, fromAttempts: state.fromAttempts)
        state.check = check
    }

    public func submit() {
        let s = state
        let problem = PinPolicy.check(s.pin)
        if s.current.isEmpty { return }
        if s.withPassword && s.password.isEmpty { return }
        if let problem {
            state.problem = problem
            state.step = .new
            state.pin = ""
            state.confirm = ""
        } else if s.pin == s.current {
            state.same = true
            state.step = .new
            state.pin = ""
            state.confirm = ""
        } else if s.pin != s.confirm {
            state.mismatch = true
            state.confirm = ""
        } else {
            send(s)
        }
    }

    private func send(_ s: ChangePinState) {
        state.busy = true
        state.error = nil
        state.check = nil
        let vault = vault
        work.launch { [weak self] in
            var failed: VaultFailure?
            do {
                if s.withPassword {
                    try await vault.changePin(pin: s.current, newPin: s.pin, password: s.password)
                } else {
                    try await vault.changePin(pin: s.current, newPin: s.pin)
                }
            } catch {
                failed = error as? VaultFailure ?? VaultFailure(.other)
            }
            guard let self else { return }
            guard let failed else {
                state = ChangePinState(withPassword: s.withPassword)
                state.done = true
                vault.acknowledgeChangeCheck()
                return
            }
            if let check = vault.changeCheck, check.type == .pin, check.undecided, failed.kind == .changeUnresolved {
                // §11.14.9 step 2: no failure; the new PIN is kept while the change is decided.
                state = Self.kept(s, current: false)
                state.check = check.status
                vault.waitForChangeCheck(self)
            } else if failed.code == VaultManager.codeChangeNotApplied {
                state = Self.kept(s, current: false)
                state.check = .notApplied
                vault.acknowledgeChangeCheck()
            } else {
                self.failed(failed.kind, kept: s)
                vault.acknowledgeChangeCheck()
            }
        }
    }

    /// A new form keeping [s]'s new PIN (and its confirmation), and the current PIN when [current].
    private static func kept(_ s: ChangePinState, current: Bool) -> ChangePinState {
        var next = ChangePinState(withPassword: s.withPassword, fromAttempts: s.fromAttempts)
        next.pin = s.pin
        next.confirm = s.confirm
        if current { next.current = s.current }
        return next
    }

    /// A refusal shown as it is (§11.14.9 step 4), with the entry that was wrong cleared: a wrong PIN clears the current
    /// PIN, a wrong password the password (the confirmation is typed again on the keypad with it); the new PIN stays. Any
    /// other failure has every entry typed again, from the current PIN (on the iPhone's keypad steps; vettid-android
    /// clears the current PIN and the password): chosen; not in the spec.
    private func failed(_ kind: FailureKind, kept s: ChangePinState) {
        var next: ChangePinState
        switch kind {
        case .badPin:
            next = Self.kept(s, current: false)
        case .badPassword:
            next = Self.kept(s, current: true)
            next.confirm = ""
            next.step = .confirm
        default:
            next = ChangePinState(withPassword: s.withPassword, fromAttempts: s.fromAttempts)
        }
        next.error = kind
        state = next
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
