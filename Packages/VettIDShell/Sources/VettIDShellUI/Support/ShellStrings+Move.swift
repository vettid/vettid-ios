import Foundation

/// The open app's notices about a move (vettid-android `app` `strings.xml`, word for word).
enum ShellMoveStrings {
    static var rootFinishMove: String {
        String(
            localized: "root_finish_move",
            defaultValue: """
                Finish moving your vault to this phone: enter your PIN on this phone.
                """,
            bundle: .module
        )
    }

    static var rootFinishMoveAction: String {
        String(localized: "root_finish_move_action", defaultValue: "Finish the move", bundle: .module)
    }

    static var rootMovedBack: String {
        String(
            localized: "root_moved_back",
            defaultValue: """
                This phone is your vault's phone again. Start the move again when you are ready.
                """,
            bundle: .module
        )
    }

    /// The day-7 check has no definite answer (owner decision, 2026-10-23; VAULT-MESSAGING §11.14.10 "The day-7 check").
    static var rootKeptCheckWaiting: String {
        String(
            localized: "root_kept_check_waiting",
            defaultValue: """
                Your vault has not confirmed the move to this phone. Once your new phone opens your vault, remove \
                VettID from this phone.
                """,
            bundle: .module
        )
    }

    static var rootMovedAway: String {
        String(
            localized: "root_moved_away",
            defaultValue: """
                Your vault has moved to your new phone. VettID has removed its keys from this phone.
                """,
            bundle: .module
        )
    }
}
