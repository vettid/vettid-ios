import Foundation

// The failure text of a move not yet finished (VAULT-MESSAGING 0.83.11 §11.14.10), apart from ``DataStrings`` for its length.
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
}
