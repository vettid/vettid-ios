import SwiftUI
import Testing
import UIKit
@testable import VettID

/// The app lock's window (IOS-PLAN ID17): above every window the app presents (sheets, full-screen covers and alerts),
/// below the privacy shield, and it takes the keyboard while shown.
@MainActor
struct AppLockWindowTests {
    @Test func theLockCoversAlertsAndSheetsAndTakesTheKeyboard() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let lock = AppLockWindow.install(on: scene)
        #expect(AppLockWindow.install(on: scene) === lock, "one per scene")
        #expect(AppLockWindow.level > .alert && AppLockWindow.level < .alert + 1)
        // A presented sheet or alert lives in the app's windows, at most at the alert level.
        let presented = UIWindow(windowScene: scene)
        presented.windowLevel = .alert
        presented.isHidden = false
        defer { presented.isHidden = true }
        lock.show(AnyView(Text(verbatim: "locked")), rebuild: true)
        #expect(lock.isShown && lock.window.isKeyWindow)
        #expect(lock.window.windowLevel > presented.windowLevel)
        lock.hide()
        #expect(!lock.isShown && !lock.window.isKeyWindow)
    }
}
