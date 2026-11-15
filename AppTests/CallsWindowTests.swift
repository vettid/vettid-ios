import SwiftUI
import Testing
import UIKit
import VettIDCallsUI
import VettIDUI
@testable import VettID

/// The calls' window (IOS-PLAN §6.6): above the app's sheets and alerts, below the app lock's window and the privacy shield's (the
/// app lock covers a call without ending it), without the keyboard, and modal for VoiceOver.
@MainActor
struct CallsWindowTests {
    private func scene() throws -> UIWindowScene {
        try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    }

    @Test func theLevelIsAboveTheAppAndBelowTheLockAndTheShield() {
        #expect(CallsWindow.level == .alert)
        #expect(CallsWindow.level > .normal)
        #expect(CallsWindow.level < AppLockWindow.level, "the app lock covers a call screen")
        #expect(AppLockWindow.level < PrivacyShield.windowLevel)
    }

    @Test func itIsOnePerSceneAndShowsAndHides() throws {
        let scene = try scene()
        let calls = CallsWindow.install(on: scene)
        #expect(CallsWindow.install(on: scene) === calls, "one per scene")
        calls.show(AnyView(Text(verbatim: "call")), rebuild: true)
        #expect(calls.isShown && calls.window.windowLevel == CallsWindow.level)
        calls.hide()
        #expect(!calls.isShown)
    }

    /// No keyboard sits over a call screen: the field the member was typing in lets go when the window comes up.
    @Test func theKeyboardIsGivenUpWhenTheCallComesUp() throws {
        let scene = try scene()
        let app = UIWindow(windowScene: scene)
        let field = UITextField()
        app.addSubview(field)
        app.makeKeyAndVisible()
        defer { app.isHidden = true }
        #expect(field.becomeFirstResponder())
        let calls = CallsWindow.install(on: scene)
        calls.show(AnyView(Text(verbatim: "call")), rebuild: true)
        defer { calls.hide() }
        #expect(!field.isFirstResponder)
    }

    /// While the app lock covers the app VoiceOver does not read the call screen (its window is under the lock's, and read through it).
    @Test func theCallScreenIsHiddenFromVoiceOverWhileTheAppLockCoversIt() throws {
        let calls = CallsWindow.install(on: try scene())
        calls.hideFromAccessibility(true)
        #expect(calls.window.rootViewController?.view.accessibilityElementsHidden == true)
        calls.hideFromAccessibility(false)
        #expect(calls.window.rootViewController?.view.accessibilityElementsHidden == false)
    }

    /// A secure field (a PIN or a password being typed) keeps the keyboard under an incoming call; any other field lets go.
    @Test func aSecureFieldKeepsTheKeyboardAndAPlainOneLetsGo() throws {
        let scene = try scene()
        let app = UIWindow(windowScene: scene)
        let plain = UITextField()
        let secure = UITextField()
        secure.isSecureTextEntry = true
        app.addSubview(plain)
        app.addSubview(secure)
        app.makeKeyAndVisible()
        defer { app.isHidden = true }
        #expect(secure.becomeFirstResponder())
        CallsWindow.resignKeyboard(of: scene)
        #expect(secure.isFirstResponder, "the PIN or password keeps it")
        #expect(plain.becomeFirstResponder())
        CallsWindow.resignKeyboard(of: scene)
        #expect(!plain.isFirstResponder)
    }

    @Test func theAppUnderTheCallIsHiddenFromVoiceOver() throws {
        let calls = CallsWindow.install(on: try scene())
        #expect(calls.window.rootViewController?.view.accessibilityViewIsModal == true)
    }
}
