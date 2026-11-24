import Foundation

// The failure texts of a move not yet finished (VAULT-MESSAGING 0.83.11 §11.14.10, §6.7.1), apart from ``DataStrings``
// for its length.
extension DataStrings {
    /// `transfer_incomplete` to a move-gated request (the move to this phone is not finished).
    /// (Owner-approved 2026-11-04: VAULT-MESSAGING 0.83.11 §11.14.10; the key vettid-android's.)
    static var failureMoveNotFinished: String {
        String(
            localized: "data_failure_move_not_finished",
            defaultValue: """
                The move to this phone isn't finished. Use Finish the move on this phone, then try again.
                """,
            bundle: .module
        )
    }

    /// iPhone only (no Android, spec or IOS-PLAN §14 text; chosen; not in the spec; owner-approved): a setup code, an
    /// enrollment, a recovery or a start-over refused while a move to this phone is under way
    /// (``VaultManager/codeTransferWaiting``).
    static var failureTransferWaiting: String {
        String(
            localized: "data_failure_ios_transfer_waiting",
            defaultValue: "A move from your old phone to this phone is still under way. Wait until it ends, then try again.",
            bundle: .module
        )
    }
}
