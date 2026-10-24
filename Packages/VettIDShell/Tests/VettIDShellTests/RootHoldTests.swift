import Testing
import VettIDData
@testable import VettIDShell

/// The root while "Finish the move" runs (VAULT-MESSAGING §11.14.10). Mirrors vettid-android `holdsRoot`.
@Suite struct RootHoldTests {
    @Test func theLastPhaseIsKeptWhileTheMoveFinishes() {
        // The move's lock takes the phase to locked; the screen that asked stays.
        #expect(RootHold.shown(phase: .locked, held: .unlocked, finishingMove: true) == .unlocked)
        #expect(RootHold.shown(phase: .unlocked, held: .setup(.finishing), finishingMove: true) == .setup(.finishing))
        #expect(RootHold.holds(phase: .locked, finishingMove: true))
    }

    @Test func thePhaseIsFollowedOnceTheMoveEnds() {
        #expect(RootHold.shown(phase: .locked, held: .unlocked, finishingMove: false) == .locked)
        #expect(RootHold.shown(phase: .unlocked, held: .locked, finishingMove: false) == .unlocked)
        #expect(!RootHold.holds(phase: .locked, finishingMove: false))
    }

    @Test func aVaultBeingDeletedIsAlwaysShown() {
        #expect(RootHold.shown(phase: .deleting, held: .unlocked, finishingMove: true) == .deleting)
        #expect(!RootHold.holds(phase: .deleting, finishingMove: true))
    }

    /// Only the move's own lock and unlock are held: a wipe during the finish is shown at once.
    @Test func aWipeDuringTheMoveIsShownAtOnce() {
        #expect(RootHold.shown(phase: .signedOut, held: .unlocked, finishingMove: true) == .signedOut)
        #expect(!RootHold.holds(phase: .signedOut, finishingMove: true))
    }
}
