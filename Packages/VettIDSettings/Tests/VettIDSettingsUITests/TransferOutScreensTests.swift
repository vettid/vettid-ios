#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings
@testable import VettIDSettingsUI
import VettIDUI

// swiftlint:disable line_length

/// Move to a new phone, the old phone's side: its texts (vettid-android's, word for word), every step rendered, the PIN on
/// the keypad, and the route that leaves the transfer when the screen goes. Mirrors vettid-android's `TransferOutContent` and
/// the screen part of `TransferOutViewModelTest`.
@MainActor
@Suite struct TransferOutScreensTests {
    let pending = TransferPendingView(transferID: "01JTRANSFER000000000000000", name: "Pixel 10 Pro", sas: "042817")

    /// Every key of the package's `Localizable.xcstrings` resolves, in the built bundle, to its own non-empty text.
    @Test func everyStringResolves() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDSettingsUI/Resources/Localizable.xcstrings")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = try #require((doc["strings"] as? [String: Any])?.keys)
        #expect(keys.count == 446)
        let missing = "\u{0}missing"
        for key in keys {
            let text = Bundle.module.localizedString(forKey: key, value: missing, table: nil)
            #expect(!text.isEmpty && text != key && text != missing, "\(key)")
        }
    }

    @Test func theTextsAreAndroids() {
        #expect(TransferStrings.securityTransfer == "Move to a new phone")
        #expect(TransferStrings.securityTransferBody == "Direct transfer: no waiting, with your PIN and password")
        #expect(TransferStrings.transferStart == "Show the code" && TransferStrings.transferMatch == "The codes match")
        #expect(TransferStrings.transferStepsBody.hasPrefix("1. On the new phone, install VettID") && TransferStrings.transferStepsBody.contains("\n2. Show the code here"))
        #expect(TransferStrings.transferExpires("9:59") == "Valid for 9:59 more" && TransferStrings.transferWindow("4:02") == "4:02 left to approve")
        #expect(TransferStrings.transferCompareBody("Pixel 10 Pro") == "Pixel 10 Pro wants to take over your vault. Continue only if it shows the same code.")
        #expect(TransferStrings.transferApproveConfirmTitle("Pixel 10 Pro") == "Move VettID to Pixel 10 Pro?")
        #expect(TransferStrings.transferWait("0:30") == "Too many wrong tries. Try again in 0:30.")
        #expect(TransferStrings.transferMovedKeptBody("7 days") == "Finish the move on your new phone. This phone keeps your vault's keys until your new phone has finished the move, for at most 7 days. Before you give this phone away, remove VettID from it or reset it.")
        #expect(TransferStrings.transferSignerContinue == "Continue" && TransferStrings.transferSignerCancel == "Cancel")
        #expect(TransferStrings.transferSignerUnconfirmed == "Your vault asked you to confirm the new phone's version of VettID first. Nothing was counted; enter your PIN and password again.")
    }

    @Test func theTimesAndTheClipboard() {
        #expect(TransferOutContent.mmss(600) == "10:00" && TransferOutContent.mmss(65) == "1:05" && TransferOutContent.mmss(0) == "0:00")
        // A copied code stays for the time it is valid, never past 5 minutes.
        #expect(TransferOutContent.clipboardLifetime(secondsLeft: 600) == 300 && TransferOutContent.clipboardLifetime(secondsLeft: 42) == 42)
        #expect(TransferOutContent.clipboardLifetime(secondsLeft: 0) == 0)
    }

    @Test func theErrorsHaveTheirOwnWords() {
        #expect(TransferError.text(.other, "exists", 1) == TransferStrings.transferExists)
        #expect(TransferError.text(.credentialFrozen, nil, 1) == TransferStrings.transferAlarm)
        #expect(TransferError.text(.rotationRequired, nil, 1) == TransferStrings.transferAlarm)
        #expect(TransferError.text(.network, nil, 1) == FailureKind.network.message)
    }

    private func state(_ step: TransferOutStep, _ edit: (inout TransferOutState) -> Void = { _ in }) -> TransferOutState {
        var s = TransferOutState()
        s.step = step
        s.offer = TransferOfferView(transferID: pending.transferID, qrPayload: #"{"v":2,"t":"p"}"#, link: "eyJ2Ijoy", expiresAt: .now)
        s.pending = pending
        s.secondsLeft = 540
        edit(&s)
        return s
    }

    var allStates: [(String, TransferOutState)] {
        [
            ("intro", state(.intro) { $0.offer = nil; $0.pending = nil }),
            ("intro, another transfer open", state(.intro) { $0.error = .other; $0.errorCode = "exists" }),
            ("showing", state(.showing)),
            ("compare", state(.compare)),
            ("signer", state(.signer) { $0.pending?.signerChanged = true; $0.pending?.signer = "vettid" }),
            ("signer, unconfirmed", state(.signer) { $0.signerUnconfirmed = true }),
            ("approve", state(.approve)),
            ("approve, typed", state(.approve) { $0.password = "correct horse battery" }),
            ("approve, wrong pin", state(.approve) { $0.error = .badPin }),
            ("approve, wrong password", state(.approve) { $0.error = .badPassword }),
            ("approve, wait", state(.approve) { $0.error = .backoff; $0.waitSeconds = 30 }),
            ("approve, alarm", state(.approve) { $0.error = .credentialFrozen }),
            ("approving", state(.approve) { $0.busy = true }),
            ("expired", state(.expired) { $0.offer = nil }),
            ("rejected", state(.rejected) { $0.offer = nil }),
            ("moved", state(.moved) { $0.offer = nil }),
            ("moved, kept", state(.moved) { $0.keptKeys = true; $0.keptForSeconds = 604_800 }),
            ("moved, kept on staging", state(.moved) { $0.keptKeys = true; $0.keptForSeconds = 25_200; $0.stagingNote = "Staging: 1 day = 1 hour" }),
        ]
    }

    @Test func everyStepRenders() {
        for (name, s) in allStates {
            #expect(height(TransferOutContent(state: s)) > 0, "\(name)")
            #expect(height(TransferOutContent(state: s, onOpenRecovery: {})) > 0, "\(name) with the link to Recovery")
        }
        var confirming = state(.approve) { $0.password = "correct horse battery" }
        confirming.confirmApprove = true
        var rejecting = state(.compare)
        rejecting.confirmReject = true
        for s in [confirming, rejecting] {
            #expect(height(TransferOutContent(state: s)) > 0)
        }
    }

    /// The PIN is the in-app keypad's (IOS-PLAN §6.5): no step has a text field for it; the approval's one text field is the
    /// credential password's, a secure one.
    @Test func thePinHasNoKeyboard() {
        for (name, s) in allStates {
            let window = host(TransferOutContent(state: s))
            let fields = textFields(in: window)
            if s.step == .approve {
                #expect(fields.count == 1 && fields.first?.isSecureTextEntry == true, "\(name): the password only")
            } else {
                #expect(fields.isEmpty, "\(name)")
            }
            window.isHidden = true
        }
    }

    /// Leaving the screen, whatever took it away, cancels a transfer that is still open: the code cannot be used later
    /// (the I3.3a review: the screen owns its model and calls `leave()` when it goes).
    @Test func theRouteLeavesTheTransferWhenItGoes() async throws {
        let vault = FakeVaultRepository(.unlocked)
        let clock = VirtualTime()
        vault.offer = TransferOfferView(
            transferID: pending.transferID, qrPayload: "{}", link: "link", expiresAt: clock.now().addingTimeInterval(600)
        )
        let model = TransferOutViewModel(move: vault, vault: vault, now: clock.now, sleep: clock.sleep)
        model.create()
        await clock.runCurrent()
        #expect(model.state.step == .showing)
        var window: UIWindow? = host(TransferOutRoute(move: vault, vault: vault, onOpenRecovery: nil, onBack: {}, model: model))
        #expect(vault.lastTransferRejected == nil)
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
        let rejected = await eventually { vault.lastTransferRejected == pending.transferID }
        #expect(rejected, "the open code was cancelled")
        #expect(model.state.step == .intro && model.state.offer == nil)
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

// swiftlint:enable line_length
#endif
