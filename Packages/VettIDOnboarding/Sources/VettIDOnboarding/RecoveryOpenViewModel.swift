import Foundation
import Observation
import VettIDData

/// `vault.recovery.open` (VAULT-MESSAGING 0.33.0 §11.14.6): the PIN and the password together, checked by the member before
/// they are sent (a wrong entry uses one of ten attempts), then the vault's answer. The release R recovery's one screen for
/// both secrets (ANDROID-PLAN 0.1.40, IOS-PLAN §8 I3.4). Mirrors vettid-android `RecoveryOpenViewModel`.
@MainActor
@Observable
public final class RecoveryOpenViewModel {
    static let codeWrong = "wrong"
    static let codeWrongAgain = "wrong_again"
    static let codeLost = "attempt_lost"
    static let codeWait = "wait"
    private static let codeDeviceSecretAnswer = "device_secret"
    private static let codeNoBundleAnswer = VaultManager.codeNoBundle

    public private(set) var state: RecoveryOpenState

    @ObservationIgnored private let move: any MoveRepository
    @ObservationIgnored private let account: any AccountRepository
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private var openingApp = false

    public init(move: any MoveRepository, account: any AccountRepository) {
        self.move = move
        self.account = account
        state = RecoveryOpenState(used: move.recoveryAttemptsUsed)
        // A recovery the vault already answered `ok` (before a restart, or whose handshake failed): finished, never opened
        // again.
        work.launch { [weak self] in
            let opened = (try? await move.recoveryOpened()) ?? false
            // Not over a step the member has moved to meanwhile.
            if opened, self?.state.step == .enter { self?.state.step = .finish }
        }
    }

    deinit { work.cancelAll() }

    public func setPin(_ v: String) {
        state.pin = String(v.filter { $0.isASCII && $0.isNumber }.prefix(RecoveryOpenState.maxPin))
    }

    public func setPassword(_ v: String) { state.password = v }

    public func toggleShowPin() { state.showPin.toggle() }

    public func toggleShowPassword() { state.showPassword.toggle() }

    /// Continue: the check-before-sending step (never skipped).
    public func review() {
        if state.canContinue { state.step = .check }
    }

    /// "Change": back to the fields, the entries kept.
    public func change() { state.step = .enter }

    public func send() {
        let s = state
        let finishing = s.step == .finish
        let ready = finishing ? s.pinValid : s.step == .check && s.canContinue
        guard ready else { return }
        state.step = .sending
        state.failure = nil
        state.failureCode = nil
        work.launch { [weak self, move] in
            let out: RecoveryOpenOutcome
            do {
                if finishing && s.lostOk {
                    out = try await move.resumeLostOk(pin: s.pin)
                } else {
                    out = try await move.recoveryOpen(pin: s.pin, password: s.password)
                }
            } catch {
                // No answer, or the vault said `ok` and the rest failed: then the PIN finishes it, nothing is opened again.
                let opened = (try? await move.recoveryOpened()) ?? finishing
                let e = (error as? VaultFailure) ?? VaultFailure(.other)
                guard let self else { return }
                state.step = opened ? .finish : .answered
                state.failure = e.kind
                state.failureCode = e.code
                state.outcome = nil
                return
            }
            self?.answered(out)
        }
    }

    /// The vault's answer (or this phone's own unlock while finishing an `ok` recovery).
    private func answered(_ out: RecoveryOpenOutcome) {
        if out.ok {
            var s = RecoveryOpenState(step: .done, used: out.used ?? state.used)
            s.outcome = out
            state = s
        } else if out.opened {
            // This phone's own unlock while finishing an `ok` recovery (a wrong PIN, a wait): nothing of the recovery used.
            // Resuming a lost `ok`, the vault's `device_secret`: this phone is not in its unlock keys, the recovery did not
            // complete onto it (as without a bundle): said so, with the way back.
            var shown = out
            if state.lostOk && out.code == Self.codeDeviceSecretAnswer { shown.code = Self.codeNoBundleAnswer }
            state.step = .finish
            state.outcome = shown
            state.failure = nil
            state.pin = ""
        } else {
            state.step = .answered
            state.outcome = out
            state.used = out.used ?? state.used
            state.rightButIncomplete = out.afterUnanswered && (out.code == Self.codeWait || out.code == Self.codeLost)
            // A wrong pair is changed before the next try; anything that used nothing keeps the entries.
            if out.code == Self.codeWrong || out.code == Self.codeWrongAgain { state.password = "" }
        }
    }

    /// From an answer: back to the fields for another try (the PIN kept).
    public func again() {
        state.step = .enter
        state.outcome = nil
        state.failure = nil
        state.failureCode = nil
        state.lostOk = false
    }

    /// (0.34.0) The open's answer was lost or unreadable, or the recovery ended after such an open: the PIN may finish a
    /// recovery that completed on the way (an unlock with this phone's secret; no attempt is used).
    public func finishLostOk() {
        state.step = .finish
        state.lostOk = true
        state.outcome = nil
        state.failure = nil
        state.failureCode = nil
        state.password = ""
    }

    public func askErase() {
        if state.canErase { state.confirmErase = true }
    }

    public func dismissErase() { state.confirmErase = false }

    /// Confirmed: VettID is erased from this phone; the phase becomes signed out and the welcome screen follows.
    public func erase() {
        guard state.confirmErase else { return }
        state.confirmErase = false
        state.pin = ""
        state.password = ""
        work.launch { [account] in try? await account.eraseThisPhone() }
    }

    /// After the `ok` text: the app opens. Then ``RecoveryOpenState/opened``, for the screen to finish setup if the app is not
    /// open yet (the `ok` text is the recovered phone's last setup screen). Continue may be pressed again after a failure; it
    /// opens nothing twice. A failure never opens anything: a lock asked for meanwhile (``MoveCodes/lockPending``) keeps the
    /// phone locked and is said as the unlock screen says it.
    public func openApp() {
        guard state.step == .done, !openingApp else { return }
        openingApp = true
        work.launch { [weak self, move] in
            defer { self?.openingApp = false }
            var failure: VaultFailure?
            do {
                try await move.finishRecoveryOpen()
            } catch is CancellationError {
                return
            } catch let f as VaultFailure {
                failure = f
            } catch {
                // Anything else (the account record's write): not opened, said as a failure, and the screen stays.
                failure = VaultFailure(.other, code: MoveCodes.notOpened)
            }
            guard let self else { return }
            if let failure {
                state.failure = failure.kind
                state.failureCode = failure.code
                state.opened = false
            } else {
                state.failure = nil
                state.failureCode = nil
                state.opened = true
            }
        }
    }

    /// TEST ONLY: returns once what the model started has run as far as it can.
    func settle() async {
        for _ in 0..<100 { await Task.yield() }
        await work.settle()
    }
}
