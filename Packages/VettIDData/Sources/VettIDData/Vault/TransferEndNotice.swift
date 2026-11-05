import Foundation

/// How a move to this phone that was waited for in the background (after a restart, with nobody on the transfer screen)
/// ended without completing (§11.14.10 rule 5).
public enum TransferEnd: Sendable, Equatable {
    /// The old phone did not approve it before the deadline and the window of collects after it: dropped.
    case timedOut
    /// The old phone declined it (`device.pair.rejected`).
    case declined
    /// Its session ended during the window (`mailbox_unknown`, or the app signed out or wiped) before this phone could
    /// tell whether the old phone approved (§11.14.10 rule 5).
    case stopped
}

/// The welcome screen's notice of a move that ended in the background without completing, until
/// ``acknowledgeTransferEnd()``. Part of ``VaultRepository``.
@MainActor
public protocol TransferEndNotice: AnyObject {
    var transferEnd: TransferEnd? { get }

    func acknowledgeTransferEnd()
}

public extension TransferEndNotice {
    var transferEnd: TransferEnd? { nil }
    func acknowledgeTransferEnd() {}
}

/// The transfer to this phone and the screen that waits for it (§11.14.10 rule 5): the stored start the screen counts
/// from, and the wait handed to the manager when the screen goes after the vault's 10 minutes (it can no longer be
/// abandoned). Part of ``MoveRepository``.
@MainActor
public protocol TransferInBackground: AnyObject {
    var transferStartedAt: Date? { get }
    /// No abandon (nor a new code) now: from the end of the vault's 10 minutes, and while the settlement window runs.
    var abandonClosed: Bool { get }

    func waitForTransferInBackground()
}

public extension TransferInBackground {
    var transferStartedAt: Date? { nil }
    var abandonClosed: Bool { false }
    func waitForTransferInBackground() {}
}
