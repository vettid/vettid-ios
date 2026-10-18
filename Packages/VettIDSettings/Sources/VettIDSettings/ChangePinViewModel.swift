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
    /// The last change got no answer: the vault may hold the new PIN already. The new PIN is kept for a resend
    /// (chosen; not in the spec).
    public var mayHaveChanged = false

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

    public init(vault: any VaultRepository, fromAttempts: Bool = false) {
        self.vault = vault
        state = ChangePinState(withPassword: vault.usesPhoneSecret, fromAttempts: fromAttempts)
    }

    deinit { work.cancelAll() }

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
            // After a change that got no answer, the same new PIN goes again: it is only confirmed.
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
        state = ChangePinState(withPassword: state.withPassword, fromAttempts: state.fromAttempts)
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
            if let failed {
                // Every entry is typed again, from the current PIN (on the iPhone's keypad steps; vettid-android clears
                // the current PIN and the password): chosen; not in the spec. Without an answer the new PIN is kept, so
                // that a resend carries the same one.
                var next = ChangePinState(withPassword: s.withPassword, fromAttempts: s.fromAttempts)
                next.error = failed.kind
                if failed.code == VaultManager.codeChangeUnanswered {
                    next.mayHaveChanged = true
                    next.pin = s.pin
                }
                state = next
            } else {
                state = ChangePinState(withPassword: s.withPassword)
                state.done = true
            }
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
