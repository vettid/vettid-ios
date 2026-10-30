import SwiftUI
import UIKit
import VettIDData
import VettIDOnboardingUI
import VettIDUI

/// The app lock over the app (ANDROID-PLAN D6; IOS-PLAN ID17). While locked, the lock screen is shown in a window of its
/// own above everything the app shows, sheets and alerts included (``AppLockWindow``, below the privacy shield's), and it
/// takes the keyboard: nothing typed reaches the app. The content underneath is kept (its navigation and drafts come back
/// on unlock, as vettid-android's saveable state does) but hidden from sight and VoiceOver and takes no touches. The
/// prompt is asked for when the lock shows and on every return to the foreground while locked; ``UnlockPromptGate`` makes
/// that idempotent. While the lock's settings are not read yet (the iPhone not unlocked since it started), the start
/// screen covers the app. Mirrors vettid-android `AppLockGate`.
struct AppLockGate<Content: View>: View {
    let lock: AppLock
    let themeMode: ThemeMode
    @ViewBuilder let content: () -> Content
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.vettIDColors) private var colors
    @State private var scene: UIWindowScene?

    private var covered: Bool { lock.state == .locked || lock.state == .pending }

    var body: some View {
        ZStack {
            content()
                .disabled(covered)
                .accessibilityHidden(covered)
                .opacity(covered ? 0 : 1)
            if covered { colors.background.color.ignoresSafeArea().accessibilityHidden(true) }
        }
        .background(SceneProbe { scene = $0 }.frame(width: 0, height: 0))
        .onChange(of: scene) { _, _ in update() }
        .onChange(of: covered) { _, _ in update() }
        .onChange(of: themeMode) { _, _ in update(rebuild: true) }
        .onChange(of: lock.state) { _, now in if now == .locked { prompt(auto: true) } }
        .onChange(of: scenePhase) { _, now in
            switch now {
            case .active:
                lock.onForeground()
                if lock.state == .locked { prompt(auto: true) }
            case .background:
                lock.onBackground()
            default:
                break
            }
        }
        .onAppear { if lock.state == .locked { prompt(auto: true) } }
    }

    /// Shows or hides the lock's window for the current state.
    private func update(rebuild: Bool = false) {
        guard let scene else { return }
        let w = AppLockWindow.install(on: scene)
        if covered {
            // No text field of the app keeps the keyboard.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            w.show(AnyView(AppLockLayer(lock: lock) { prompt(auto: false) }.vettIDTheme(themeMode)), rebuild: rebuild)
        } else {
            w.hide()
        }
    }

    private func prompt(auto: Bool) {
        Task { await lock.unlock(reason: AppLockTexts.reason, auto: auto) }
    }
}

/// What the lock's window shows: the lock screen, or the start screen while the lock's settings are not read yet.
struct AppLockLayer: View {
    let lock: AppLock
    let onUnlock: @MainActor () -> Void

    var body: some View {
        switch lock.state {
        case .locked:
            AppLockScreen(passcodeOnly: lock.method == .passcode, lockedOut: lock.lockedOut, onUnlock: onUnlock)
                .accessibilityIdentifier("app_lock_layer")
        case .pending, .disabled, .unlocked:
            StartingScreen()
        }
    }
}

/// The app lock's window for one window scene, above every window of the app (sheets, full-screen covers and alerts
/// included) and below the privacy shield's. It takes the keyboard while shown, and gives it back to the app's window
/// when hidden.
@MainActor
final class AppLockWindow {
    private static var installed: [ObjectIdentifier: AppLockWindow] = [:]
    static let level = UIWindow.Level.alert + 0.5

    private weak var scene: UIWindowScene?
    let window: UIWindow
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var built = false

    /// The window of [scene], made once.
    static func install(on scene: UIWindowScene) -> AppLockWindow {
        let id = ObjectIdentifier(scene)
        if let w = installed[id] { return w }
        let w = AppLockWindow(scene)
        installed[id] = w
        return w
    }

    private init(_ scene: UIWindowScene) {
        self.scene = scene
        window = UIWindow(windowScene: scene)
        window.windowLevel = Self.level
        window.rootViewController = host
        window.isHidden = true
        window.accessibilityIdentifier = "app_lock_window"
    }

    var isShown: Bool { !window.isHidden }

    func show(_ view: AnyView, rebuild: Bool = false) {
        if !built || rebuild {
            host.rootView = view
            built = true
        }
        guard window.isHidden else { return }
        window.makeKeyAndVisible()
        // VoiceOver moves into the lock, which came up by itself.
        Announcer.screenChanged()
    }

    func hide() {
        guard !window.isHidden else { return }
        window.isHidden = true
        scene?.windows.first { $0 !== window && $0.windowLevel == .normal }?.makeKey()
        Announcer.screenChanged()
    }
}

/// Finds the window scene of the view it sits in.
private struct SceneProbe: UIViewRepresentable {
    let found: @MainActor (UIWindowScene) -> Void

    final class Probe: UIView {
        var found: (@MainActor (UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { found?(scene) }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let p = Probe()
        p.isUserInteractionEnabled = false
        p.found = found
        return p
    }

    func updateUIView(_ uiView: Probe, context: Context) {}
}
