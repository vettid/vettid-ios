#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboardingUI
import VettIDUI

/// The notices of a move, above every screen of the open app (release R, VAULT-MESSAGING §11.14.10): a move to this phone
/// that is not finished is asked about at every start in the open app, with "Finish the move" in a sheet (on the unlock
/// screen the unlock itself finishes it); the old phone that took the vault back ("The move didn't finish" succeeded), the
/// move that did not happen after the 7 days, and the keys removed from the old phone are each told once, until "OK". The
/// sheet stays through the lock and unlock it sends (and cannot be dismissed while they run). Mirrors vettid-android
/// `MoveNotices`.
struct MoveNotices: View {
    @Environment(\.vettIDColors) private var colors
    let vault: any VaultRepository
    @State private var finishMoveOpen = false

    var body: some View {
        VStack(spacing: 0) {
            if vault.finishMovePending, !vault.finishingMove {
                InfoBanner(
                    ShellMoveStrings.rootFinishMove, actionLabel: ShellMoveStrings.rootFinishMoveAction,
                    onAction: { finishMoveOpen = true }
                )
                .accessibilityIdentifier("finish_move_banner")
            }
            if vault.movedBack {
                InfoBanner(
                    ShellMoveStrings.rootMovedBack, actionLabel: ShellStrings.ownerCheckNoticeOk,
                    onAction: { vault.acknowledgeMovedBack() }
                )
                .accessibilityIdentifier("moved_back_banner")
            }
            // The vault confirmed at the end of the 7 days that this phone is still its app: the move did not happen.
            if vault.moveNotDone {
                InfoBanner(
                    ShellMoveStrings.rootMoveNotDone, actionLabel: ShellStrings.ownerCheckNoticeOk,
                    onAction: { vault.acknowledgeMoveNotDone() }
                )
                .accessibilityIdentifier("move_not_done_banner")
            }
            // The old phone removed its keys (the new phone finished the move, or 7 days passed): said once.
            if vault.movedAway {
                InfoBanner(
                    ShellMoveStrings.rootMovedAway, actionLabel: ShellStrings.ownerCheckNoticeOk,
                    onAction: { vault.acknowledgeMovedAway() }
                )
                .accessibilityIdentifier("moved_away_banner")
            }
        }
        .sheet(isPresented: Binding(get: { finishMoveOpen && vault.finishMovePending }, set: { finishMoveOpen = $0 })) {
            FinishMoveRoute(vault: vault) { if !vault.finishingMove { finishMoveOpen = false } }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(colors.background.color)
                .interactiveDismissDisabled(vault.finishingMove)
                .environment(\.vettIDColors, colors)
        }
    }
}
#endif
