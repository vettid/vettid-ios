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
/// `MoveNotices`. Drawn by the root above every phase, so that the notice of a wipe (``movedAway``) is seen on the welcome screen.
public struct MoveNotices: View {
    @Environment(\.vettIDColors) private var colors
    let vault: any VaultRepository
    let phase: AppPhase
    @State private var finishMoveOpen = false

    public init(vault: any VaultRepository, phase: AppPhase) {
        self.vault = vault
        self.phase = phase
    }

    /// The sheet is offered while the vault is open, and kept through the lock and unlock it sends.
    static func showsSheet(pending: Bool, phase: AppPhase, finishingMove: Bool) -> Bool {
        pending && (phase == .unlocked || finishingMove)
    }

    private var showsSheet: Bool {
        Self.showsSheet(pending: vault.finishMovePending, phase: phase, finishingMove: vault.finishingMove)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if vault.finishMovePending, phase == .unlocked {
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
            // 7 days or more after the approval and the vault has not answered the check: the keys are kept, and the member is told
            // what to do (owner decision, 2026-10-23); the check is made again at each start and foreground.
            if vault.keptCheckPending {
                InfoBanner(ShellMoveStrings.rootKeptCheckWaiting)
                    .accessibilityIdentifier("kept_check_waiting_banner")
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
        .sheet(isPresented: Binding(get: { finishMoveOpen && showsSheet }, set: { finishMoveOpen = $0 })) {
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
