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

/// A transfer to this phone that the transfer screen takes up again when it opens (``AppPhase/setup(_:)`` with
/// ``SetupStage/transferWaiting``: after a restart, or the screen left). Mirrors vettid-android `TransferInWaiting` and
/// `MoveRepository.takeTransferStopped`.
public enum TransferInWaiting: Equatable, Sendable {
    /// Its comparison code was shown (the `hs.fin` is out or owed) and the old phone may still approve it, or the
    /// settlement at its deadline runs: the code again, counted from the stored start of its `hs.init`.
    case waiting(sas: String, startedAt: Date)
    /// (§6.7.1) It stopped on this phone (a `device.paired` without a valid `user_guid`, dropped unapplied) before the
    /// member was told: "The move stopped on this phone", once.
    case stopped
}

/// The transfer to this phone and the screen that waits for it (§11.14.10 rule 5): the stored start the screen counts
/// from, and the wait handed to the manager when the screen goes after the vault's 10 minutes (it can no longer be
/// abandoned). Part of ``MoveRepository``.
@MainActor
public protocol TransferInBackground: AnyObject {
    var transferStartedAt: Date? { get }
    /// No abandon (nor a new code) now: from the end of the vault's 10 minutes, and while the settlement window runs.
    var abandonClosed: Bool { get }
    /// The old phone can no longer approve: from the end of the vault's 10 minutes, and while the settlement window runs.
    /// The screen then shows its check in place of the comparison code. Not for a start adopted with its real start
    /// unknown: its code is still compared, although no abandon is offered (``abandonClosed``).
    var transferChecking: Bool { get }

    func waitForTransferInBackground()
    /// (VAULT-MESSAGING 0.88.4 §11.14.10 rule 5) Whether [text] is the open transfer's own code, whatever its expiry: the
    /// screen then hands it to ``MoveRepository/transferIn(code:)`` (which gives the move back) instead of refusing it as
    /// expired, and never abandons the transfer for it.
    func isOpenTransferCode(_ text: String) -> Bool
    /// The transfer to this phone the screen takes up as it opens, if one is not finished; the screen's wait then takes
    /// the place of the background's. Nil when there is none to show (the screen starts afresh).
    func transferInWaiting() async throws -> TransferInWaiting?
}

public extension TransferInBackground {
    var transferStartedAt: Date? { nil }
    var abandonClosed: Bool { false }
    var transferChecking: Bool { abandonClosed }
    func waitForTransferInBackground() {}
    func isOpenTransferCode(_ text: String) -> Bool { false }
    func transferInWaiting() async throws -> TransferInWaiting? { nil }
}
