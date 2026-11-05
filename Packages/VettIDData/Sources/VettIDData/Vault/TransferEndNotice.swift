import Foundation

/// How a move to this phone that was waited for in the background (after a restart, with nobody on the transfer screen)
/// ended without completing (§11.14.10 rule 5).
public enum TransferEnd: Sendable, Equatable {
    /// The old phone did not approve it before the deadline and the window of collects after it: dropped.
    case timedOut
    /// The old phone declined it (`device.pair.rejected`).
    case declined
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
