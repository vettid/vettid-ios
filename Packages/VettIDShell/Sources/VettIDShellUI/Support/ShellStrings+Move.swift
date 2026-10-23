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

    static var rootMoveNotDone: String {
        String(
            localized: "root_move_not_done",
            defaultValue: """
                Your vault did not move to your new phone: it still works with this phone, which keeps its keys. \
                Start the move again when you are ready.
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
