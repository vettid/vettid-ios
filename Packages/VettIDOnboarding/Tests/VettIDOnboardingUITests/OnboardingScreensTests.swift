#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDOnboarding
@testable import VettIDOnboardingUI
import VettIDUI

/// The onboarding screens' texts, routes and inputs. The texts are vettid-android's, word for word. (Every state of the
/// app's screen catalog renders: AppTests `OnboardingCatalogTests`. vettid-android's `OnboardingScreensTest` checks the backup acknowledgement with Compose's test
/// rule; here ``OnboardingState/canContinueBackup``, which the screen uses as is, is checked in the model's tests.)
@MainActor
@Suite struct OnboardingScreensTests {
    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme()).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    /// "Opening VettID" renders with and without the way out it offers after a long read.
    @Test func theStartingScreenRenders() async {
        // The stuck state, reached through the model with a bound of zero (the clock is the model's).
        let stuck = StartingViewModel(stuckAfter: .zero, sleep: { _ in }, reread: {})
        await stuck.watch()
        #expect(stuck.stuck && height(StartingScreen(model: stuck)) > 0)
        #expect(height(StartingScreen()) > 0)
        #expect(height(StartingScreen(reread: {}, stuckAfter: .zero)) > 0)
    }

    /// Every screen that sends a PIN, a password or a code says a wait the same way (a `429` or a backoff).
    @Test func aWaitIsSaidTheSameEverywhere() {
        let t0 = ContinuousClock.now
        let wait = WaitDeadline(seconds: 90, now: t0)
        for kind in [FailureKind.rateLimited, .backoff] {
            #expect(WaitText.message(kind, retryAt: wait, timeScale: 1, now: t0).hasPrefix("Too many attempts. Try again in "))
            #expect(WaitText.spoken(kind, retryAt: wait, now: t0)?.hasPrefix("Too many attempts. Try again in ") == true)
        }
        // A field's spoken error is the same at every tick: only the visible text counts down.
        let later = t0.advanced(by: .seconds(1))
        func shown(_ now: ContinuousClock.Instant) -> String { WaitText.message(.backoff, retryAt: wait, timeScale: 1, now: now) }
        func spoken(_ now: ContinuousClock.Instant) -> String? {
            WaitText.steadySpoken(.backoff, retryAt: wait, timeScale: 1, now: now)
        }
        #expect(shown(t0) != shown(later))
        #expect(spoken(t0) == spoken(later) && spoken(t0) != nil)
        #expect(WaitText.steadySpoken(.badPin, retryAt: wait, timeScale: 1, now: t0) == nil)
        // A long wait is h:mm:ss, not "120:00".
        #expect(WaitText.clock(90) == "1:30" && WaitText.clock(3_599) == "59:59" && WaitText.clock(7_200) == "2:00:00")
        #expect(WaitText.message(.badPin, retryAt: wait, timeScale: 1, now: t0) == FailureKind.badPin.message)
        #expect(WaitText.spoken(.badPin, retryAt: wait, now: t0) == nil && WaitText.spoken(.rateLimited, retryAt: nil) == nil)
        // Over: the failure's own text, and nothing held back.
        let over = t0.advanced(by: .seconds(91))
        #expect(WaitText.message(.backoff, retryAt: wait, timeScale: 1, now: over) == FailureKind.backoff.message)
        #expect(wait.isRunning(now: t0) && !wait.isRunning(now: over))
    }

    /// A rate-limited redeem says how long to wait (Android's text of the recovery); no wait left, the general text.
    @Test func aRateLimitedRedeemSaysTheWait() {
        let soon = Date().addingTimeInterval(90)
        #expect(ErrorNotice.message(.rateLimited, soon, timeScale: 1).hasPrefix("Too many attempts. Try again in "))
        #expect(ErrorNotice.message(.rateLimited, nil, timeScale: 1) == FailureKind.rateLimited.message)
        #expect(ErrorNotice.message(.rateLimited, Date().addingTimeInterval(-5), timeScale: 1) == FailureKind.rateLimited.message)
    }

    /// iPhone only: a refused start-over says from when it is possible; without a time, the general text.
    @Test func aRefusedStartOverSaysWhen() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let text = ErrorNotice.message(.enrollmentStarted, at, timeScale: 1)
        #expect(text == FailureKind.enrollmentStartedText(after: at) && text.contains("start over after"))
        #expect(ErrorNotice.message(.enrollmentStarted, nil, timeScale: 1) == FailureKind.enrollmentStarted.message)
        #expect(ErrorNotice.message(.network, at, timeScale: 1) == FailureKind.network.message)
    }

    /// Every key of the package's `Localizable.xcstrings` resolves, in the built bundle, to its own non-empty text.
    @Test func everyStringResolves() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDOnboardingUI/Resources/Localizable.xcstrings")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = try #require((doc["strings"] as? [String: Any])?.keys)
        #expect(keys.count == 477)
        let missing = "\u{0}missing"
        // vettid-android's names: the onboarding feature's, its unlock, owner-check and app-lock screens', the app's root
        // screens', core/ui's erase text, the release update's and What's new's, a vault being deleted (`vault_delet`,
        // IOS-PLAN §4.2); and the iPhone's own (`ios_`).
        let prefixes = [
            "onboarding_", "recover_scan_", "unlock_", "root_", "core_ui_", "ios_", "move_cd_", "ownercheck_", "app_lock_", "release_",
            "vault_deleting_", "vault_deleted_", "transfer_in_", "recover_", "move_",
        ]
        for key in keys {
            let text = Bundle.module.localizedString(forKey: key, value: missing, table: nil)
            #expect(!text.isEmpty && text != key && text != missing, "\(key)")
            #expect(prefixes.contains { key.hasPrefix($0) }, "\(key)")
        }
    }

    @Test func theTextsAreAndroids() {
        // A vault being deleted: the texts of vettid-android #192.
        #expect(OnboardingStrings.vaultDeletingUnconfirmed == "This phone can't confirm the deletion.")
        #expect(OnboardingStrings.vaultDeletingRemove == "Remove from this phone")
        #expect(OnboardingStrings.vaultDeletingRemoveConfirmTitle == "Remove VettID from this phone?")
        #expect(OnboardingStrings.vaultDeletingRemoveConfirm == "Remove")
        #expect(OnboardingStrings.vaultDeletingClockHint == "Also check that the date and time on this phone are right.")
        #expect(OnboardingStrings.vaultDeletingStill == "VettID has not finished yet. Tap Check again later, or check the account site.")
        #expect(OnboardingStrings.vaultDeletingCannotConfirm == "VettID answered, but this phone cannot confirm that the deletion is "
            + "finished. When you get the email that your vault was deleted, or the account site offers to set up a new vault, remove "
            + "VettID from this phone.")
        #expect(OnboardingStrings.vaultDeletingSlowBody == "Your vault can no longer be opened, but this phone cannot confirm that "
            + "VettID has finished deleting it. When you get the email that your vault was deleted, or the account site offers to set up "
            + "a new vault, remove VettID from this phone.")
        #expect(OnboardingStrings.vaultDeletingRemoveConfirmBody == "Your vault can never be opened again, and nothing on this phone "
            + "is needed to finish deleting it. This removes VettID's data on this phone only: its keys, your account details and the "
            + "app's settings. It works without a connection and cannot be undone.")
        #expect(OnboardingStrings.welcomeTitle == "Your vault, only with you")
        #expect(OnboardingStrings.welcomePointKeys == "Your keys stay on this phone and in your vault's sealed enclave.")
        #expect(OnboardingStrings.setupOtherEnvironment("https://account.example.org") == "That code is from another VettID "
            + "environment (https://account.example.org), not the one this app uses. Get a code from this app's account site.")
        #expect(OnboardingStrings.confirmAccountBody("m***@example.com") == "You are setting up a vault for m***@example.com. "
            + "Only continue if this is your own account and you got the code yourself.")
        #expect(OnboardingStrings.setupRecoveryCode
            == #"That is a recovery code. To recover your vault, go back and choose "I lost my phone"."#)
        #expect(OnboardingStrings.backupOffAck == "I understand that without this phone my vault cannot be recovered")
        #expect(OnboardingStrings.recoverScanPermissionBody == "VettID uses the camera only to read the code; nothing is recorded.")
        #expect(!OnboardingStrings.setupScanBody.contains("\n"))
        #expect(OnboardingStrings.setupScanBody.hasSuffix("It works once, for 5 minutes."))
        #expect(Set(EnrollStep.allCases.map(\.label)).count == EnrollStep.allCases.count)
    }

    /// The routes of later rows get the flow's callbacks.
    @Test func theMoveStepsGoToTheirRoutes() {
        let shown = Log()
        let routes = OnboardingRoutes(
            recover: { _, _, _ in shown.items.append("recover"); return AnyView(EmptyView()) },
            transferIn: { _ in shown.items.append("transfer"); return AnyView(EmptyView()) },
            movedIn: { _, _ in shown.items.append("moved"); return AnyView(EmptyView()) }
        )
        var moved = OnboardingState(step: .done)
        moved.movedIn = true
        for state in [OnboardingState(step: .recover), OnboardingState(step: .transferIn), moved] {
            let host = UIHostingController(
                rootView: OnboardingContent(state: state, actions: NoOnboardingActions(), routes: routes, onOpenAccountSite: {})
            )
            _ = host.sizeThatFits(in: CGSize(width: 390, height: 844))
        }
        #expect(shown.items == ["recover", "transfer", "moved"])
    }

    /// The setup code is typed on a keyboard that does not suggest, correct or learn it, and AutoFill is off (IOS-PLAN
    /// §6.5). Mirrors vettid-android `CodeKeyboardsTest.theSetupCode`: the field the screen really shows is read.
    @Test func theSetupCodeKeyboard() throws {
        var state = OnboardingState(step: .setupType)
        state.codeInput = "K7QM"
        let window = host(SetupTypeScreen(state: state, actions: NoOnboardingActions(), onBack: nil))
        let field = try #require(textFields(in: window).first { $0.placeholder == SetupTypeScreen.placeholder })
        #expect(field.textContentType?.rawValue == "")
        #expect(field.autocorrectionType == .no && field.spellCheckingType == .no && field.inlinePredictionType == .no)
        #expect(field.smartQuotesType == .no && field.smartDashesType == .no && field.smartInsertDeleteType == .no)
        #expect(field.keyboardType == .asciiCapable && field.autocapitalizationType == .allCharacters)
        #expect(!field.isSecureTextEntry, "the member reads the code while typing it")
        #expect(field.text == "K7QM")
        window.isHidden = true
    }

    /// Without a usable camera (the simulator, or a restricted one) the scan screen shows the card that offers to type
    /// the code, never the camera.
    @Test func withoutACameraTheCodeIsTyped() {
        #if targetEnvironment(simulator)
        #expect(CameraAccess.current() == .unavailable)
        #endif
        let card = ScannerBox(onText: { _ in }, onTypeInstead: {}, camera: nil, access: .unavailable).vettIDTheme()
        let window = host(card)
        #expect(!views(in: window).contains { $0 is QrScannerView.PreviewView })
        let height = UIHostingController(rootView: card).sizeThatFits(in: CGSize(width: 358, height: 1000)).height
        #expect(height > 0 && height < 320, "a card, not the camera's frame")
        window.isHidden = true

        let camera = host(ScannerBox(onText: { _ in }, onTypeInstead: {}, camera: nil, access: .granted).vettIDTheme())
        #expect(views(in: camera).contains { $0 is QrScannerView.PreviewView })
        camera.isHidden = true
    }

    /// [view] in a window of its own, laid out.
    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }

    private func textFields(in view: UIView) -> [UITextField] { views(in: view).compactMap { $0 as? UITextField } }
}

@MainActor
private final class Log {
    var items: [String] = []
}
#endif
