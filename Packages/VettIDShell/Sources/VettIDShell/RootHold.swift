import Foundation
import VettIDData

/// Which phase the root shows while "Finish the move" runs (release R, VAULT-MESSAGING §11.14.10): the move's lock and unlock
/// take the phase to `.locked` for a moment, and the screen that asked (the open app, or onboarding's last screen) must stay
/// until the outcome, or its model, and the work it started, would be freed under it. Mirrors vettid-android `holdsRoot`.
public enum RootHold {
    /// The phase to show: [held] (the last phase shown before the move began) while [finishingMove] runs and the phase is one
    /// the move's own lock and unlock pass through (locked, unlocked); any other phase (a wipe, a vault being deleted) is
    /// shown at once; otherwise [phase].
    public static func shown(phase: AppPhase, held: AppPhase, finishingMove: Bool) -> AppPhase {
        holds(phase: phase, finishingMove: finishingMove) ? held : phase
    }

    /// Whether what a phase change ends (the shell's place, the screenshot allowance) waits: while the root is held.
    public static func holds(phase: AppPhase, finishingMove: Bool) -> Bool {
        finishingMove && (phase == .locked || phase == .unlocked)
    }
}
