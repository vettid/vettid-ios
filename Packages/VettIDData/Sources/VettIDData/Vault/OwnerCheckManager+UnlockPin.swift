import Foundation

// The PIN the unlock's check leaves for the check screen (IOS-PLAN §6.6; VAULT-MESSAGING §3.6.5 "Ask only for what is used").
extension OwnerCheckManager {
    /// The unlock of a vault that may be past its deadline (§3.6.5): reads `vault.status` and, if the vault is held or
    /// due, sends the check with the same entries; the answer waits in ``unlockCheckOutcome``. After a wrong password with
    /// tries left, or a backoff, the accepted [pin] is kept for the check screen's password-only retry
    /// (``takeUnlockPin()``), unless the app left the front, or the vault locked or was wiped, or another unlock began,
    /// meanwhile. An answer to a check sent before another unlock, a lock made here or a wipe is dropped. [left]: what
    /// ``startUnlockPin()`` returned before the unlock request was sent (nil: taken now): leaving the front from then on
    /// drops the PIN; anything else that ends it counts from here, once the vault opened (a `vault.locking` that arrives
    /// while the unlock request is on its way is the late notice of an earlier lock).
    func afterUnlock(pin: String, password: String, left: Int? = nil) async {
        let left = left ?? startUnlockPin()
        forgetUnlockPin()
        unlockEpoch += 1
        let (unlock, kept) = (unlockEpoch, pinEpoch)
        markOpen()
        forgetEstimate()
        endIdleLocked()
        let v = try? await readStatus().view
        guard unlock == unlockEpoch, let v, v.gated(now()) else { return }
        let r = await checkOutcome(pin: pin, password: password, holdOff: nil)
        guard unlock == unlockEpoch else { return }
        unlockCheckOutcome = r
        if Self.keepsPin(r), kept == pinEpoch, left == leftFront, inFront, !lockedByOwnerCheck { unlockPin = pin }
    }

    /// Whether the check screen asks for the password only, with the unlock's PIN: a wrong password with a try left, or a
    /// backoff (no try used).
    public nonisolated static func keepsPin(_ r: OwnerCheckOutcome) -> Bool {
        switch r {
        case .badPassword(let left, _): (left ?? 0) > 0
        case .backoff: true
        default: false
        }
    }

    public func takeUnlockPin() -> String? {
        defer { unlockPin = nil }
        return unlockPin
    }

    /// Called before an unlock that may keep its PIN is sent: drops a PIN kept earlier, and returns the count of the app's
    /// leaves, so that leaving the front during the unlock request itself drops the PIN too.
    func startUnlockPin() -> Int {
        forgetUnlockPin()
        return leftFront
    }

    /// The app entered the foreground or left it (IOS-PLAN §6.6; ``VaultManager/onForeground()``,
    /// ``VaultManager/onBackground(budget:)``): leaving drops the kept PIN, also while the unlock and its check are on
    /// their way (§3.6.5: both are then asked for again).
    public func setForeground(_ front: Bool) {
        inFront = front
        if !front {
            leftFront += 1
            forgetUnlockPin()
        }
    }

    /// Drops the kept PIN, and the one an unlock's check has not yet decided to keep.
    func forgetUnlockPin() {
        unlockPin = nil
        pinEpoch += 1
    }
}
