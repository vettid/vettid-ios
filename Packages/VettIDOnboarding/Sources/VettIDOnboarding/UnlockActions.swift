import Foundation

/// What the unlock screen can ask for: ``UnlockViewModel``, or ``NoUnlockActions`` in previews and the screen catalog.
/// Mirrors vettid-android `UnlockActions`.
@MainActor
public protocol UnlockActions: AnyObject, Sendable {
    func retryPreflight()
    func acknowledgeUpdate()
    func setApproveOffer(_ approve: Bool)
    /// The PIN from the keypad, handed over once, right before ``submit()``.
    func setPin(_ v: String)
    /// The credential password, asked for with the PIN when the owner check is due (§3.6.5).
    func setPassword(_ v: String)
    func submit()
    func cancelRecoveryAndUnlock()
    /// (iPhone, IOS-PLAN §6.3 item 5) The member's tap on "Try this phone's earlier keys", with the PIN just handed over.
    func submitEarlierSecret()
    /// Shows or hides the recovery and transfer help under the `signer_refused` notice.
    func showSignerHelp(_ show: Bool)
    /// Opens the "Erase VettID from this phone" confirmation (only when ``UnlockState/eraseOffered``).
    func askErase()
    /// Closes it; nothing is erased.
    func dismissErase()
    /// The member confirmed: erases this phone, then the welcome screen.
    func confirmErase()
    /// Tries the unconfirmed lock again now.
    func retryLock()
    /// The member has read that the vault confirmed the lock.
    func dismissLockNotice()
    /// The member has read why "Finish the move" did not finish.
    func dismissMoveFailure()
    /// (iPhone, IOS-PLAN §6.3) The app left the foreground or the iPhone is locking: typed secrets are dropped.
    func forgetSecrets()
}

/// Actions that do nothing: the screen rendered with sample states (previews, the screen catalog).
@MainActor
public final class NoUnlockActions: UnlockActions {
    public init() {}

    public func retryPreflight() {}
    public func acknowledgeUpdate() {}
    public func setApproveOffer(_ approve: Bool) {}
    public func setPin(_ v: String) {}
    public func setPassword(_ v: String) {}
    public func submit() {}
    public func cancelRecoveryAndUnlock() {}
    public func submitEarlierSecret() {}
    public func showSignerHelp(_ show: Bool) {}
    public func askErase() {}
    public func dismissErase() {}
    public func confirmErase() {}
    public func retryLock() {}
    public func dismissLockNotice() {}
    public func dismissMoveFailure() {}
    public func forgetSecrets() {}
}
