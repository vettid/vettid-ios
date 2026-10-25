import Foundation
import Observation
import VettIDData

/// The vault deletion's state. The PIN (from the keypad, handed over with the first press) and the password live here
/// only until the answer, and are dropped when the app leaves the foreground. Never printed: the description names no
/// secret. Mirrors vettid-android `DeleteVaultUiState`, with what the iPhone says of a lost answer.
public struct DeleteVaultState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The shortest PIN the deletion takes (vettid-android `MIN_PIN`).
    public static let minPin = 4

    public var phrase = ""
    public var pin = ""
    public var password = ""
    public var acknowledged = false
    /// The final confirmation is shown.
    public var confirming = false
    public var phraseWrong = false
    public var busy = false
    public var error: FailureKind?
    /// (iPhone; chosen, not in the spec) The deletion got no answer and the account service still lists the vault: it may
    /// or may not have been deleted. Said so, with a check that sends nothing to the vault.
    public var unconfirmed = false
    /// (iPhone; chosen, not in the spec) After such a deletion, the account service still lists the vault more than a
    /// minute past the request's `exp`: it was not deleted, and no copy of the request can delete it any more.
    public var notDeleted = false

    public init() {}

    /// Whether the deletion can go, with [pinTyped] digits on the keypad (the PIN is handed over with the first press).
    public func ready(pinTyped: Int) -> Bool {
        DeletePhrase.matches(phrase) && pinTyped >= Self.minPin && !password.isEmpty && acknowledged
    }

    public var description: String {
        "DeleteVaultState(ready: \(ready(pinTyped: pin.count)), busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"), "
            + "unconfirmed: \(unconfirmed), notDeleted: \(notDeleted))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// `vault.delete` (VAULT-MESSAGING §12.5) by the holder: the exact phrase, the PIN and the credential password, an
/// acknowledgement, then a final confirmation. After the vault's answer "being deleted" follows (the phase). A lost
/// answer is checked with the account service (``VaultRepository/checkVaultDeleted()``), never by sending the PIN again
/// on its own. Mirrors vettid-android `DeleteVaultViewModel`.
@MainActor
@Observable
public final class DeleteVaultViewModel {
    public private(set) var state = DeleteVaultState()

    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let work = Work()

    public init(vault: any VaultRepository) {
        self.vault = vault
    }

    deinit { work.cancelAll() }

    public func setPhrase(_ v: String) {
        state.phrase = v
        state.phraseWrong = false
    }

    /// The PIN from the keypad, handed over once with the first press.
    public func setPin(_ v: String) {
        state.pin = String(v.filter { $0.isASCII && $0.isNumber }.prefix(PinPolicy.maxLength))
        state.error = nil
    }

    public func setPassword(_ v: String) {
        state.password = v
        state.error = nil
    }

    public func setAcknowledged(_ v: Bool) { state.acknowledged = v }

    /// First press: checks the phrase and asks for the final confirmation.
    public func submit() {
        guard DeletePhrase.matches(state.phrase) else {
            state.phraseWrong = true
            return
        }
        if state.ready(pinTyped: state.pin.count) { state.confirming = true }
    }

    /// The final confirmation was cancelled. The PIN goes with it: the keypad shows none (chosen; not in the spec, where
    /// vettid-android's field keeps it).
    public func cancelConfirm() {
        guard state.confirming else { return }
        state.confirming = false
        state.pin = ""
    }

    public func confirm() {
        let s = state
        guard s.ready(pinTyped: s.pin.count), !s.busy else { return }
        state.confirming = false
        state.busy = true
        state.error = nil
        state.unconfirmed = false
        state.notDeleted = false
        let vault = vault
        work.launch { [weak self] in
            var failed: VaultFailure?
            do {
                try await vault.deleteVault(pin: s.pin, password: s.password)
            } catch {
                failed = error as? VaultFailure ?? VaultFailure(.other)
            }
            guard let self else { return }
            guard let failed else {
                state = DeleteVaultState()
                return
            }
            state.busy = false
            state.pin = ""
            state.password = ""
            if failed.code == VaultManager.codeDeleteUnconfirmed {
                state.unconfirmed = true
            } else {
                state.error = failed.kind
            }
        }
    }

    /// After a lost answer: asks the account service whether the vault is gone (nothing is sent to the vault).
    /// Nothing is erased; not deleted (and never to be): said so; otherwise the notice stays.
    public func checkAgain() {
        guard state.unconfirmed, !state.busy else { return }
        state.busy = true
        let vault = vault
        work.launch { [weak self] in
            let found = (try? await vault.checkVaultDeleted()) ?? .undecided
            guard let self else { return }
            state.busy = false
            switch found {
            case .deleted: state = DeleteVaultState()
            case .notDeleted:
                state.unconfirmed = false
                state.notDeleted = true
            case .undecided: break
            }
        }
    }

    /// The app leaving the foreground or the iPhone locking (IOS-PLAN §6.3): the PIN and the password are dropped, and the
    /// final confirmation with them. A deletion on its way stays busy.
    public func forgetSecrets() {
        state.pin = ""
        state.password = ""
        state.confirming = false
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
