import SwiftUI
import UIKit

/// Keeps the screen on while a screen waits for the vault (the transfer's comparison, the enrolment, a cold start): the
/// auto-lock would put the app in the background, stop the collection after 25 s and suspend the member API's poll, and
/// the wait would end in a failure text on return (IOS-PLAN §6.6; chosen; not in the spec). The idle timer is back on as
/// soon as no screen asks for it. Several screens may ask at once.
@MainActor
public enum ScreenOn {
    private static var holders = 0

    static func hold() {
        holders += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release() {
        holders = max(holders - 1, 0)
        if holders == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// How many screens ask for the screen to stay on now (the tests' view).
    public static var asking: Int { holders }
}

private struct KeepScreenOn: ViewModifier {
    let active: Bool
    @State private var held = false

    func body(content: Content) -> some View {
        content
            .onAppear { sync() }
            .onChange(of: active) { sync() }
            .onDisappear { if held { ScreenOn.release(); held = false } }
    }

    private func sync() {
        if active, !held {
            ScreenOn.hold()
            held = true
        } else if !active, held {
            ScreenOn.release()
            held = false
        }
    }
}

public extension View {
    /// The screen stays on while [active] and this view is shown.
    func keepsScreenOn(_ active: Bool = true) -> some View { modifier(KeepScreenOn(active: active)) }
}
