#if os(iOS)
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
import VettIDCrypto
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding
@testable import VettIDOnboardingUI
import VettIDUI

// swiftlint:disable line_length

/// The move to this phone: the transfer from the old phone and "Finish the move" (VAULT-MESSAGING §6.7.1, §11.14.10). The
/// texts (vettid-android's, word for word), every step rendered, the PIN on the keypad, a hold that empties it, and the route
/// that leaves a transfer when the screen goes. Mirrors vettid-android's `TransferInContent`, `FinishMovePane` and the screen
/// part of `FinishMoveHoldTest`.
@MainActor
@Suite struct MoveScreensTests {
    @Test func theTextsAreAndroids() {
        #expect(MoveStrings.transferInTitle == "Move from your old phone" && MoveStrings.transferInScan == "Scan the code")
        #expect(MoveStrings.transferInPaste == "Paste the code instead" && MoveStrings.transferInPasteLabel == "Transfer code")
        #expect(MoveStrings.transferInWaiting("9:59") == "Waiting for your old phone (9:59 left)")
        #expect(MoveStrings.transferInNotTransfer == "That is not a transfer code. On your old phone, open Settings, then Move to a new phone.")
        #expect(MoveStrings.transferInExpiredCode == "That code has expired. Show a new one on your old phone.")
        #expect(MoveStrings.transferInNoAnswerTitle == "No answer from your vault" && MoveStrings.transferInScanNew == "Scan a new code")
        #expect(MoveStrings.onboardingFinishMoveBody == "Enter your PIN on this phone to finish moving your vault.")
        #expect(MoveStrings.onboardingFinishMoveDone == "Your vault is on this phone now." && MoveStrings.onboardingFinishMoveLater == "Later")
        #expect(MoveStrings.onboardingMovedTitle == "Your vault is connected to this phone now" && MoveStrings.onboardingMovedGo == "Go to VettID")
        #expect(MoveStrings.moveBack == "Back" && MoveStrings.recoverNeedTitle == "You will need" && MoveStrings.recoverFailedTitle == "Something went wrong")
        #expect(OnboardingStrings.finishMoveTitle == "Finish the move")
    }

    var transferSteps: [(String, TransferInState)] {
        func with(_ step: TransferInStep, _ edit: (inout TransferInState) -> Void = { _ in }) -> TransferInState {
            var s = TransferInState(step: step)
            edit(&s)
            return s
        }
        return [
            ("intro", with(.intro)),
            ("intro, no answer", with(.intro) { $0.error = .noResponse }),
            ("intro, network", with(.intro) { $0.error = .network }),
            ("scan", with(.scan)),
            ("scan, not a transfer code", with(.scan) { $0.inputProblem = .inviteInvalid }),
            ("scan, expired", with(.scan) { $0.inputProblem = .inviteExpired }),
            ("paste", with(.paste)),
            ("paste, typed", with(.paste) { $0.input = "eyJ2Ijoy" }),
            ("paste, refused", with(.paste) { $0.input = "x"; $0.inputProblem = .inviteInvalid }),
            ("paste, running", with(.paste) { $0.input = "eyJ2Ijoy"; $0.busy = true }),
            ("connecting", with(.connecting) { $0.busy = true }),
            ("compare", with(.compare) { $0.sas = "042817"; $0.secondsLeft = 540 }),
            ("done", with(.done)),
            ("done, phone secret", with(.done) { $0.phoneSecret = true }),
            ("done, no user_guid", with(.done) { $0.canUnlockLater = false }),
            ("rejected", with(.rejected)),
            ("timed out", with(.timedOut)),
            ("not answered", with(.notAnswered)),
        ]
    }

    @Test func everyStepRenders() {
        let camera = AnyView(Color.gray)
        for (name, s) in transferSteps {
            #expect(height(TransferInContent(state: s, camera: camera)) > 0, "\(name)")
        }
        var failures: [FinishMoveState] = [FinishMoveState()]
        var held = FinishMoveState()
        held.held = .changeChecking
        var running = FinishMoveState()
        running.busy = true
        var failed = FinishMoveState()
        failed.failure = .transferIncomplete
        var done = FinishMoveState()
        done.done = true
        failures += [held, running, failed, done]
        for s in failures {
            #expect(height(FinishMoveContent(state: s)) > 0)
        }
        var fresh = OnboardingState()
        fresh.movedIn = true
        var pendingMove = fresh
        pendingMove.finishMovePending = true
        let vault = FakeVaultRepository(.setup(.finishing))
        for s in [fresh, pendingMove] {
            #expect(height(MovedInScreen(state: s, vault: vault, finish: {})) > 0)
        }
    }

    /// The code is pasted in a field without suggestions, and the PIN is the keypad's: no step has a text field.
    @Test func noKeyboardForThePinOrAutofillForTheCode() {
        for (name, s) in transferSteps {
            let window = host(TransferInContent(state: s, camera: AnyView(Color.gray)))
            #expect(textFields(in: window).isEmpty, "\(name)")
            let editors = views(in: window).compactMap { $0 as? UITextView }
            if s.step == .paste {
                #expect(editors.count == 1 && editors.allSatisfy { $0.autocorrectionType == .no && $0.spellCheckingType == .no }, "\(name)")
            }
            window.isHidden = true
        }
        var held = FinishMoveState()
        held.held = .changeChecking
        for s in [FinishMoveState(), held] {
            let window = host(FinishMoveContent(state: s))
            #expect(textFields(in: window).isEmpty && views(in: window).compactMap { $0 as? UITextView }.isEmpty)
            window.isHidden = true
        }
    }

    /// A hold begins while digits are typed: they go with it (vettid-android `FinishMoveHoldTest`, the screen's part: "a hold
    /// empties the PIN"), and the keypad is empty and unusable until the hold lifts.
    @Test func aHoldEmptiesThePin() async {
        let box = StateBox()
        let pin = PinBuffer()
        let window = host(HoldHost(box: box, pin: pin))
        for d in [4, 0, 2, 8, 1, 7] { pin.append(d) }
        #expect(pin.count == 6)
        box.state.held = .changeChecking
        let emptied = await eventually { pin.count == 0 }
        #expect(emptied, "the digits typed before the hold went with it")
        box.state.held = nil
        pin.append(1)
        #expect(pin.count == 1)
        window.isHidden = true
    }

    /// Leaving the screen with a handshake under way cancels the transfer (nothing was approved, so nothing changes); the
    /// pasted code is forgotten. After the transfer completed, nothing is cancelled.
    @Test func theRouteCancelsTheHandshakeWhenItGoes() async throws {
        for movedIn in [false, true] {
            let vault = FakeVaultRepository(.setup(.vaultElsewhere))
            vault.movedInFlag = movedIn
            let clock = VirtualTime()
            let model = TransferInViewModel(move: vault, vault: vault, now: clock.now, sleep: clock.sleep)
            model.scan()
            model.scanned(try qr(clock))
            await clock.runCurrent()
            #expect(model.state.step == .compare)
            var window: UIWindow? = host(TransferInRoute(move: vault, vault: vault, onLeave: {}, camera: nil, model: model))
            window?.rootViewController = nil
            window?.isHidden = true
            window = nil
            let abandoned = await eventually { vault.calls.contains("abandonTransferIn") }
            #expect(abandoned == !movedIn, "movedIn \(movedIn)")
        }
    }

    @Test func onlyAHandshakeUnderWayIsCancelled() {
        let cancelling: Set<TransferInStep> = [.connecting, .compare]
        for step in [TransferInStep.intro, .scan, .paste, .connecting, .compare, .done, .rejected, .timedOut, .notAnswered] {
            #expect(TransferInRoute.cancels(step) == cancelling.contains(step), "\(step)")
        }
    }

    private func qr(_ clock: VirtualTime) throws -> String {
        let exp = UInt64(clock.now().timeIntervalSince1970) + 600
        let q = InviteQr(
            kind: .app, relay: "https://relay.vettid.test", claimID: "abcdefghijklmnopqrstuvwxyz",
            hash: [UInt8](repeating: 1, count: 32), key: [UInt8](repeating: 2, count: 32), exp: exp
        )
        return try #require(String(bytes: try q.marshal(), encoding: .utf8))
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }

    private func textFields(in view: UIView) -> [UITextField] { views(in: view).compactMap { $0 as? UITextField } }

    private func eventually(within: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: within)
        while clock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// The state "Finish the move" shows, changed by a test while the screen is on a window.
@MainActor
@Observable
private final class StateBox {
    var state = FinishMoveState()
}

private struct HoldHost: View {
    let box: StateBox
    let pin: PinBuffer

    var body: some View {
        FinishMoveContent(state: box.state, pin: pin)
    }
}

// swiftlint:enable line_length
#endif
