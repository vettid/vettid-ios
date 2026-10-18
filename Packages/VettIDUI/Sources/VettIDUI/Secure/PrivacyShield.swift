import SwiftUI
import UIKit

/// The cover the app switcher shows (IOS-PLAN §6.4 protection 1): the logo on navy, nothing of the screen.
public struct PrivacyCover: View {
    public init() {}

    public var body: some View {
        ZStack {
            VettIDPalette.navy900.color.ignoresSafeArea()
            RookLogo(height: 72, decorative: true)
        }
        .accessibilityHidden(true)
    }
}

/// What replaces the app's content while the screen is recorded, mirrored, shared or on AirPlay (§6.4 protection 2).
public struct CaptureHiddenView: View {
    public init() {}

    public var body: some View {
        ZStack {
            VettIDPalette.navy900.color.ignoresSafeArea()
            VStack(spacing: Spacing.l) {
                RookLogo(height: 56, decorative: true)
                Text(UIStrings.captureHidden)
                    .vettIDFont(.bodyLarge)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(VettIDPalette.inkHigh.color)
                    .padding(.horizontal, Spacing.xl)
            }
        }
    }
}

/// The always-on protections of IOS-PLAN §6.4 for one window scene (ID10), on a window of its own above everything the
/// app shows (sheets, full-screen covers and alerts included):
/// - the cover while the scene is not active, shown synchronously when the scene is about to resign active, before the
///   app-switcher snapshot is taken;
/// - the capture text while the scene's `sceneCaptureState` is active (recording, mirroring, AirPlay, screen sharing).
///
/// The app's own views stay alive underneath: nothing they hold (navigation, typed input) is lost. Neither protection
/// depends on "Allow screenshots".
@MainActor
final class PrivacyShieldController {
    private static var installed: [ObjectIdentifier: PrivacyShieldController] = [:]

    private weak var scene: UIWindowScene?
    private let window: UIWindow
    private let cover = UIHostingController(rootView: AnyView(PrivacyCover()))
    private var inactive = false
    private var captured = false
    private var observers: [NSObjectProtocol] = []

    /// Installs the shield on [scene] once.
    static func install(on scene: UIWindowScene) {
        let id = ObjectIdentifier(scene)
        guard installed[id] == nil else { return }
        installed[id] = PrivacyShieldController(scene)
    }

    private init(_ scene: UIWindowScene) {
        self.scene = scene
        window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = cover
        window.isHidden = true
        window.accessibilityIdentifier = "privacy_shield"
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setInactive(true) }
            },
            nc.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setInactive(false) }
            },
        ]
        scene.registerForTraitChanges([UITraitSceneCaptureState.self]) { [weak self] (s: UIWindowScene, _: UITraitCollection) in
            self?.setCaptured(s.traitCollection.sceneCaptureState == .active)
        }
        inactive = scene.activationState != .foregroundActive
        captured = scene.traitCollection.sceneCaptureState == .active
        apply()
    }

    private func setInactive(_ v: Bool) {
        inactive = v
        apply()
    }

    private func setCaptured(_ v: Bool) {
        captured = v
        apply()
    }

    /// The capture text wins over the cover: both hide everything, and the text says why.
    private func apply() {
        if captured {
            cover.rootView = AnyView(CaptureHiddenView())
        } else if inactive {
            cover.rootView = AnyView(PrivacyCover().accessibilityIdentifier("privacy_cover"))
        }
        window.isHidden = !(captured || inactive)
    }

    /// Test hook: the shield's state.
    var isShown: Bool { !window.isHidden }

    static func controller(for scene: UIWindowScene) -> PrivacyShieldController? { installed[ObjectIdentifier(scene)] }
}

/// Finds the window scene of the view it sits in and installs the shield on it.
private struct ShieldInstaller: UIViewRepresentable {
    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { PrivacyShieldController.install(on: scene) }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let p = Probe()
        p.isUserInteractionEnabled = false
        return p
    }

    func updateUIView(_ uiView: Probe, context: Context) {}
}

/// What the shield of a scene shows, for the app's tests: nil when none is installed.
@MainActor
public enum PrivacyShieldState {
    public static func isShown(in scene: UIWindowScene) -> Bool? { PrivacyShieldController.controller(for: scene)?.isShown }
}

extension View {
    /// The app-switcher cover and capture hiding (IOS-PLAN §6.4 protections 1 and 2), installed on the window scene of
    /// the app's root view.
    public func privacyShield() -> some View { background(ShieldInstaller().frame(width: 0, height: 0)) }
}
