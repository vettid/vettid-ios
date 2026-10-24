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
        #expect(keys.count == 331)
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
