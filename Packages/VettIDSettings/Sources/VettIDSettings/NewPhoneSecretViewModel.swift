import Foundation
import Observation
import VettIDData

/// Settings → Security → New phone secret. The PIN (from the keypad, handed over with the submit) and the password live
/// here only until the answer, and are dropped when the app leaves the foreground. Never printed: the description names
/// no secret. Mirrors vettid-android `NewPhoneSecretUiState`.
public struct NewPhoneSecretState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The shortest PIN the submit takes (vettid-android `MIN_PIN`).
    public static let minPin = 6

    public var pin = ""
    public var password = ""
    public var busy = false
    public var error: FailureKind?
    public var done = false

    public init(error: FailureKind? = nil, done: Bool = false) {
        self.error = error
        self.done = done
    }

    /// Whether the submit can go, with [pinTyped] digits on the keypad (the PIN is handed over only with the submit).
    public func canSubmit(pinTyped: Int) -> Bool { !busy && pinTyped >= Self.minPin && !password.isEmpty }

    public var description: String { "NewPhoneSecretState(busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"), done: \(done))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// `vault.secret.renew` (VAULT-MESSAGING §11.14.9; ANDROID-PLAN "Other screens"): the PIN and the password; the vault
/// gives this phone a new secret with the PIN unchanged and replaces its DEK, so that the old secret opens nothing it
/// stores from then on. For a member who fears that something ran as the app on this phone. A lost answer keeps the
/// phone's next-epoch record (IOS-PLAN §6.3): "Try again" sends the same secret, and an unlock tries it. Mirrors
/// vettid-android `NewPhoneSecretViewModel`.
@MainActor
@Observable
public final class NewPhoneSecretViewModel {
    public private(set) var state = NewPhoneSecretState()

    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let work = Work()

    public init(vault: any VaultRepository) {
        self.vault = vault
    }

    deinit { work.cancelAll() }

    /// The PIN from the keypad, handed over once with the submit.
    public func setPin(_ v: String) {
        state.pin = String(v.filter { $0.isASCII && $0.isNumber }.prefix(PinPolicy.maxLength))
        state.error = nil
    }

    public func setPassword(_ v: String) {
        state.password = v
        state.error = nil
    }

    public func submit() {
        let s = state
        guard s.canSubmit(pinTyped: s.pin.count) else { return }
        state.busy = true
        state.error = nil
        let vault = vault
        work.launch { [weak self] in
            do {
                try await vault.renewPhoneSecret(pin: s.pin, password: s.password)
                self?.state = NewPhoneSecretState(done: true)
            } catch {
                // Neither entry is kept after an answer.
                self?.state = NewPhoneSecretState(error: failureKind(error))
            }
        }
    }

    /// Leaving the screen, or the app leaving the foreground or the iPhone locking (IOS-PLAN §6.3): nothing typed stays. A
    /// renew on its way keeps the screen busy, so this screen cannot send it twice; leaving the screen cancels the wait,
    /// and the phone's record stays a candidate for the retry or the next unlock (IOS-PLAN §6.3).
    public func forgetSecrets() {
        state.pin = ""
        state.password = ""
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
