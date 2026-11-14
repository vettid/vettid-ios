import Foundation
import VettIDData

extension OwnerCheckViewModel {
    /// A check that failed on the password or backed off, right after the unlock.
    static func isRetry(_ r: OwnerCheckOutcome) -> Bool {
        switch r {
        case .badPassword, .backoff: true
        default: false
        }
    }

    static func isBackoff(_ r: OwnerCheckOutcome) -> Bool {
        if case .backoff = r { return true }
        return false
    }

    /// Whether the kept PIN stays after the answer [r] to a retry, only where trying again can help (VAULT-MESSAGING 0.73.1
    /// §3.6.5): a wrong password with a try left (an unknown count counts as none: the vault may have locked, §3.6.4), a
    /// backoff, or a check the vault did not answer (``OwnerCheckOutcome/isUnanswered``) unless the tries are then estimated
    /// at 0 (the vault has probably locked). Any other answer drops it. As vettid-android `OwnerCheckViewModel`.
    static func keepsPin(_ r: OwnerCheckOutcome) -> Bool {
        switch r {
        case .badPassword(let left, _): (left ?? 0) > 0
        case .backoff: true
        case .failed(_, _, let left): r.isUnanswered && (left ?? 1) > 0
        default: false
        }
    }

    static func message(_ r: OwnerCheckOutcome) -> OwnerCheckMessage? {
        switch r {
        case .passed: nil
        case .badPin(let left, _): .badPin(checksLeft: left)
        case .badPassword(let left, _): .badPassword(checksLeft: left)
        case .backoff: .backoff
        case .failed(let kind, let code, _): .failed(kind, code: code)
        }
    }

    /// A check's outcome, a vault failure included (as its own outcome).
    func checkOutcome(pin: String, password: String, holdOff: HoldOff?) async -> OwnerCheckOutcome {
        do {
            return try await repo.check(pin: pin, password: password, holdOff: holdOff)
        } catch let e as VaultFailure {
            return .failed(e.kind, code: e.code)
        } catch {
            return .failed(.other, code: nil)
        }
    }

    /// The vault answered [r] to the check sent when the app had left the front [away] times ([probe]: the re-read after
    /// no answer). Mirrors vettid-android `OwnerCheckUiState.answered`.
    func answered(_ r: OwnerCheckOutcome, _ probe: VaultProbe?, away: Int) {
        // §3.6.5: neither entry is kept beyond the answer. §11.14.5: a check that passed without the presence recorded
        // keeps the screen, with the notice, until the member goes on.
        let passed = r == .passed
        let unrecorded = passed && repo.presenceUnrecorded
        // The unlock's PIN stays for another try of the password only after a wrong password (a try left), a backoff or
        // a failure that never reached the vault's verdict; it is not kept once the vault locked.
        // Decided from the state as it is now: a PIN dropped while the check was on its way (the app left the front, even
        // if it is back) does not come back when the answer lands.
        let keep = state.pinKept && Self.keepsPin(r) && !repo.lockedByOwnerCheck && repo.inFront && repo.leftFront == away
        // One change of the state, so that the shell hears the check is no longer out together with its message.
        var s = state
        var left: Int?
        if keep, case .badPassword(let n, _) = r, let n, n > 0 { left = n }
        s.busy = false
        s.pin = keep ? s.pin : ""
        s.password = ""
        // (ANDROID-PLAN 0.1.124) A pass shows the tick first; ``tickShown()`` then closes the screen. A pass that still
        // needs presence recorded keeps today's screen, with no tick.
        s.passedTick = passed && !unrecorded
        s.passedUnrecorded = unrecorded
        if passed { s.presenceUnrecorded = repo.presenceUnrecorded }
        // Locked by this answer: the label stays as it was, off (``enterLocked()``).
        s.pinKept = keep || (s.pinKept && repo.lockedByOwnerCheck)
        s.unlockedWrong = left
        s.unlockedOpen = keep && Self.isBackoff(r)
        s.message = left != nil ? nil : Self.message(after: r, probe)
        state = s
        if case .backoff(let wait) = r { startBackoff(wait) }
        if repo.lockedByOwnerCheck {
            enterLocked()
        } else if Self.needsWatch(r) {
            beginWatch()
        }
    }
}

/// How long the "Check passed" tick is held: 1 second, 3 seconds while VoiceOver is on (IOS-PLAN §4.17; no wait on the
/// announcement). Mirrors vettid-android `passedTickMillis`.
public func passedTickHold(voiceOver: Bool) -> Duration { voiceOver ? .seconds(3) : .seconds(1) }
