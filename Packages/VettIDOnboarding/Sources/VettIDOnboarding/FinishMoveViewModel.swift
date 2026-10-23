import Foundation
import Observation
import VettIDData

/// "Finish the move" on the new phone (VAULT-MESSAGING 0.33.0 §11.14.10 step 4). The PIN is the in-app keypad's and is
/// handed over once with ``FinishMoveViewModel/finish(pin:)``; it is never here. Mirrors vettid-android
/// `FinishMoveUiState`.
public struct FinishMoveState: Equatable, Sendable, CustomStringConvertible {
    public var busy = false
    public var done = false
    public var failure: FailureKind?
    /// (VAULT-MESSAGING 0.45.0 §11.14.9 step 2) A PIN or password change is being decided, or the PIN is uncertain: no lock
    /// and unlock with a PIN typed here until it is (the gate's text); nil when the move can be finished.
    public var held: FailureKind?

    public init() {}

    /// The keypad can be used: not held, not running, not done.
    public var pinAllowed: Bool { held == nil && !busy && !done }

    public var description: String {
        "FinishMoveState(busy: \(busy), done: \(done), failure: \(failure.map { "\($0)" } ?? "nil"), "
            + "held: \(held.map { "\($0)" } ?? "nil"))"
    }
}

/// Right after the transfer's `device.paired` and the credential: `vault.lock`, then `vault.unlock` with this phone's own
/// secret, which reads the stored header and state and so proves that both writes of the transfer are durable.
/// `transfer_incomplete`: "The move to this phone did not finish. Approve it again on your old phone." It can wait
/// ("Later"): the app asks again at every start, in a banner of the open app, until an unlock from storage succeeds
/// (``VaultRepository/finishMovePending``); an unlock on the unlock screen does the same. Mirrors vettid-android
/// `FinishMoveViewModel`.
@MainActor
@Observable
public final class FinishMoveViewModel {
    /// The shortest PIN the keypad hands over (Android `MIN_PIN`).
    public static let minPin = 6

    public private(set) var state = FinishMoveState() {
        didSet { keypad.follow(state.pinAllowed) { [vault] in vault.pinGeneration } }
    }

    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let followers = TaskBag()
    /// (VAULT-MESSAGING §11.14.9 step 2; chosen, not in the spec) Which PIN the vault expects, read when the keypad becomes
    /// usable and handed over with the PIN: a change sent or decided while the member types it stops the move with nothing
    /// sent, and the PIN is asked for again.
    @ObservationIgnored private let keypad = KeypadReading()

    public init(vault: any VaultRepository) {
        self.vault = vault
        keypad.follow(state.pinAllowed) { vault.pinGeneration }
        followers.add(follow(self, read: { $0.vault.finishMoveHold }, apply: { $0.state.held = $1 }))
    }

    deinit {
        work.cancelAll()
        followers.cancelAll()
    }

    /// The keypad's first digit was typed into an empty keypad: only a change while the PIN is being typed is counted
    /// against it.
    public func pinTypingStarted() {
        keypad.renew(state.pinAllowed) { [vault] in vault.pinGeneration }
    }

    /// "Finish the move" with the PIN from the keypad, handed over once. False when it was not allowed (held, running, done,
    /// or too short); then nothing is sent.
    @discardableResult
    public func finish(pin: String) -> Bool {
        guard pin.count >= Self.minPin, state.pinAllowed else { return false }
        let taken = keypad.take(state.pinAllowed) { [vault] in vault.pinGeneration }
        state.busy = true
        state.failure = nil
        work.launch { [weak self, vault] in
            let failure: FailureKind?
            do {
                failure = Self.failure(of: try await vault.finishMove(pin: pin, taken: taken))
            } catch let e as VaultFailure {
                failure = e.kind
            } catch {
                failure = .other
            }
            guard let self else { return }
            self.state.busy = false
            self.state.done = failure == nil
            self.state.failure = failure
        }
        return true
    }

    /// What the screen says after an unlock that did not open the vault; nil after a success. (chosen; Android's view model
    /// says "other" for a backoff, which the unlock screen after it names, so the wait is named here too.)
    static func failure(of r: UnlockAttempt) -> FailureKind? {
        switch r {
        case .success: nil
        case .badPin: .badPin
        case .backoff: .backoff
        case .failed(let kind, _, _): kind
        default: .other
        }
    }

    /// TEST ONLY: returns once what the model started has run.
    func settle() async { await work.settle() }
}
