import Observation
import SwiftUI
import Testing
import UIKit
@testable import VettID
import VettIDUI

/// The daily owner check covers the shell without replacing it, so that what the member had entered (an item or a rule
/// being edited, a message being written) is there after the check, and the shell under it is neither read nor
/// operated meanwhile (VAULT-MESSAGING §3.6.5; "What you entered is kept").
@MainActor
struct OwnerCheckCoverTests {
    /// A screen's view model: made once, when the screen first appears, as `ItemEditRoute`, `RuleEditRoute` and the
    /// conversation do; its draft is the typed input.
    @Observable
    final class Editor {
        var draft = ""
        var sent = 0
    }

    /// Whether the check is due, as the gate sets it.
    @Observable
    final class Due {
        var covered = false
    }

    struct Seen {
        let enabled: Bool
        let covered: Bool
        let phase: ScenePhase
    }

    struct Probe: View {
        let due: Due
        var outer = false
        @State private var editor: Editor?
        let onEditor: (Editor) -> Void
        let onEnvironment: (Bool, Bool, ScenePhase) -> Void

        var body: some View {
            Shell(editor: editor, onEnvironment: onEnvironment)
                .modifier(CoveredByCheck(covered: due.covered))
                .environment(\.vettIDCovered, outer)
                .onAppear {
                    if editor == nil {
                        let made = Editor()
                        editor = made
                        onEditor(made)
                    }
                }
        }
    }

    /// The shell's screen: an action that acts for the member, and the environment it is given.
    struct Shell: View {
        let editor: Editor?
        let onEnvironment: (Bool, Bool, ScenePhase) -> Void
        @Environment(\.scenePhase) private var phase
        @Environment(\.isEnabled) private var enabled
        @Environment(\.vettIDCovered) private var covered

        var body: some View {
            // swiftlint:disable:next redundant_discardable_let
            let _ = onEnvironment(enabled, covered, phase)
            Button("Send the draft") { editor?.sent += 1 }
        }
    }

    private func host(
        _ due: Due, outer: Bool = false, editor: @escaping (Editor) -> Void = { _ in },
        environment: @escaping (Bool, Bool, ScenePhase) -> Void = { _, _, _ in }
    ) -> (UIWindow, UIHostingController<Probe>) {
        let controller = UIHostingController(rootView: Probe(due: due, outer: outer, onEditor: editor, onEnvironment: environment))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    private func settle(_ controller: UIViewController) async {
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(50))
            controller.view.layoutIfNeeded()
        }
    }

    @Test func aDraftSurvivesTheCheckComingDueAndPassing() async {
        var made = 0
        let due = Due()
        var editor: Editor?
        let (window, controller) = host(due, editor: { editor = $0; made += 1 })
        await settle(controller)
        editor?.draft = "typed before the deadline"
        due.covered = true
        await settle(controller)
        due.covered = false
        await settle(controller)
        #expect(made == 1)
        #expect(editor?.draft == "typed before the deadline")
        window.isHidden = true
    }

    @Test func theShellUnderTheCheckIsDisabledToldItIsCoveredAndInTheBackground() async {
        let due = Due()
        var seen: [Seen] = []
        let (window, controller) = host(due, environment: { seen.append(Seen(enabled: $0, covered: $1, phase: $2)) })
        await settle(controller)
        #expect(seen.last?.enabled == true && seen.last?.covered == false)
        let before = seen.last?.phase

        due.covered = true
        await settle(controller)
        // Disabled, told it is covered (its sheets close) and in the background (typed secrets go).
        #expect(seen.last?.enabled == false && seen.last?.covered == true && seen.last?.phase == .background)

        due.covered = false
        await settle(controller)
        #expect(seen.last?.enabled == true && seen.last?.covered == false && seen.last?.phase == before)
        window.isHidden = true
    }

    @Test func anOuterCoverIsNeverLifted() async {
        let due = Due()
        var seen: [Seen] = []
        let (window, controller) = host(due, outer: true, environment: { seen.append(Seen(enabled: $0, covered: $1, phase: $2)) })
        await settle(controller)
        // The check is not covering, but "This phone can't use your vault" is: the shell is still told it is covered.
        #expect(seen.last?.covered == true)
        due.covered = true
        await settle(controller)
        due.covered = false
        await settle(controller)
        #expect(seen.last?.covered == true)
        window.isHidden = true
    }

    @Test func aScreenHoldingInputIsRegisteredWhileItDoesAndDroppedWhenItGoes() async {
        let registry = InputInProgress()
        struct Screen: View {
            let registry: InputInProgress
            let holds: Due
            var body: some View {
                Color.clear.holdsInput(holds.covered).environment(\.vettIDInput, registry)
            }
        }
        let holds = Due()
        let controller = UIHostingController(rootView: Screen(registry: registry, holds: holds))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        await settle(controller)
        #expect(!registry.active)
        holds.covered = true
        await settle(controller)
        #expect(registry.active)
        holds.covered = false
        await settle(controller)
        #expect(!registry.active)
        window.isHidden = true
    }

    // MARK: When the check covers the shell

    /// The vault's deadline of the check, which the limit is measured from.
    private let deadline = Date(timeIntervalSince1970: 1_000_000)

    private func covers(
        _ d: OwnerCheckDeferral, gated: Bool = true, input: Bool, at offset: TimeInterval = 0,
        deadline: Date? = nil, opened: Bool = false
    ) -> Bool {
        d.covers(
            gated: gated, input: input, deadline: deadline ?? self.deadline, now: self.deadline.addingTimeInterval(offset),
            opened: opened
        )
    }

    private func due() -> OwnerCheckDeferral {
        var d = OwnerCheckDeferral()
        d.gateChanged(gated: true, now: deadline)
        return d
    }

    @Test func aScreenWithoutInputIsCoveredAtTheDeadline() {
        // A read-only pushed screen (an item, a History entry, the photo viewer) or a drawer screen.
        #expect(covers(due(), input: false))
        #expect(!covers(OwnerCheckDeferral(), gated: false, input: false))
    }

    @Test func anEditorWithInputWaitsUntilTheMemberLeavesIt() {
        var d = due()
        #expect(!covers(d, input: true, at: 60))
        // Going to a deeper screen, which keeps the editor mounted, opens it.
        d.screenChanged(gated: true)
        #expect(covers(d, input: true, at: 62))
        // Leaving the screen ends its input: the check opens.
        #expect(covers(due(), input: false, at: 61))
    }

    /// (ANDROID-PLAN 0.1.124) A check the member asked for that is with the vault or shows its tick: the due check waits
    /// for it, also once armed (a return from the background, another screen) and past the limit; then it covers.
    @Test func aDueCheckWaitsForAnAskedCheckThatIsOut() {
        var d = due()
        d.screenChanged(gated: true)
        #expect(!d.covers(gated: true, input: false, deadline: deadline, now: deadline, opened: false, askedOut: true))
        #expect(!d.covers(
            gated: true, input: true, deadline: deadline, now: deadline.addingTimeInterval(OwnerCheckDeferral.limit + 60),
            opened: false, askedOut: true
        ))
        #expect(d.covers(gated: true, input: false, deadline: deadline, now: deadline, opened: false, askedOut: false))
        let open = d.covers(gated: true, input: false, deadline: deadline, now: deadline, opened: true, askedOut: true)
        #expect(open, "the open check stays")
    }

    @Test func theLimitIsMeasuredFromTheVaultsDeadline() {
        let d = due()
        #expect(!covers(d, input: true, at: OwnerCheckDeferral.limit - 1))
        #expect(covers(d, input: true, at: OwnerCheckDeferral.limit))
        #expect(OwnerCheckDeferral.limit == 300)
    }

    @Test func aRebuiltDeferralOrALateFirstObservationDoesNotRestartTheLimit() {
        // The gate view is rebuilt (a lock and unlock, a relaunch) and sees the check due 4 minutes after its deadline:
        // the limit ends at 5 minutes from the deadline, not from this sighting.
        var rebuilt = OwnerCheckDeferral()
        rebuilt.gateChanged(gated: true, now: deadline.addingTimeInterval(240))
        #expect(!covers(rebuilt, input: true, at: 299))
        #expect(covers(rebuilt, input: true, at: 300))
        var late = OwnerCheckDeferral()
        late.gateChanged(gated: true, now: deadline.addingTimeInterval(15))
        #expect(covers(late, input: true, at: 300))
    }

    @Test func aHeldCheckBeforeTheClocksDeadlineIsMeasuredFromWhenItWasSeenDue() {
        // The vault says the check is held while the phone's clock is still before the deadline (an hour ahead): the limit
        // runs from the first sighting, the earlier of the two.
        var d = OwnerCheckDeferral()
        let seen = deadline.addingTimeInterval(10)
        d.gateChanged(gated: true, now: seen)
        let ahead = deadline.addingTimeInterval(3600)
        #expect(!d.covers(gated: true, input: true, deadline: ahead, now: seen.addingTimeInterval(299), opened: false))
        #expect(d.covers(gated: true, input: true, deadline: ahead, now: seen.addingTimeInterval(300), opened: false))
    }

    @Test func aDeadlinePassedWhileInTheBackgroundCoversOnTheReturn() {
        var d = OwnerCheckDeferral()
        d.scene(.background, gated: false)
        // Not due while away as far as the app knows; on the return it is, with the deadline long past.
        d.gateChanged(gated: true, now: deadline.addingTimeInterval(3600))
        d.scene(.inactive, gated: true)
        #expect(!d.covers(gated: true, input: true, deadline: nil, now: deadline.addingTimeInterval(3600), opened: false))
        d.scene(.active, gated: true)
        #expect(covers(d, input: true, at: 3600))
        #expect(covers(OwnerCheckDeferral(), input: true, at: 3600))
    }

    @Test func onceCoveringItStaysCoveredWhateverRegistersAfterwards() {
        let d = due()
        var latch = OwnerCheckLatch()
        let first = covers(d, input: false, at: 1)
        latch.observe(first)
        #expect(latch.covered(first))
        // A screen registers input in the same frame: the raw answer turns false, the check is not taken away.
        let later = covers(d, input: true, at: 2)
        #expect(!later)
        #expect(latch.covered(later))
        // Passed: the next time it is due it waits again.
        latch.release()
        #expect(!latch.covered(covers(d, input: true, at: 3)))
    }

    @Test func aReturnFromTheBackgroundOpensButInactiveToActiveDoesNot() {
        var d = due()
        d.scene(.inactive, gated: true)
        d.scene(.active, gated: true)
        #expect(!covers(d, input: true, at: 10))
        d.scene(.inactive, gated: true)
        d.scene(.background, gated: true)
        d.scene(.inactive, gated: true)
        d.scene(.active, gated: true)
        #expect(covers(d, input: true, at: 20))
    }

    @Test func aCheckAfterACancelledRecoveryOpensAtOnceAndAnOpenedCheckStays() {
        #expect(covers(OwnerCheckDeferral(), gated: false, input: true, opened: true))
    }

    @Test func aChangeBeforeTheDeadlineDoesNotArm() {
        var d = OwnerCheckDeferral()
        d.screenChanged(gated: false)
        d.gateChanged(gated: true, now: deadline)
        #expect(!covers(d, input: true, at: 5))
    }
}
