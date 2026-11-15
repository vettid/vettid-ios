#if os(iOS)
import SwiftUI
import UIKit
import VettIDCalls
import VettIDUI

/// What a window of the calls shows: the call screen when there is one, and the microphone gate's dialogs over it (or over
/// nothing, when a Call button asked for the microphone before any call).
public struct CallsContent: View {
    let host: CallsHost

    public init(host: CallsHost) { self.host = host }

    public var body: some View {
        let state = host.uiState
        ZStack {
            if state.showsScreen {
                CallScreen(
                    state,
                    actions: CallActions(
                        onAnswer: { host.answer() }, onDecline: { host.decline() }, onHangUp: { host.hangUp() },
                        onMute: { host.toggleMute() }, onSpeaker: { host.toggleSpeaker() }, onDismiss: { host.dismiss() }
                    )
                )
            } else {
                Color.clear
            }
        }
        .modifier(MicrophoneDialogs(host: host))
    }
}

/// The microphone gate: our own explanation before the system's prompt, and where to change a refusal (iOS asks only once).
/// Mirrors vettid-android `MicrophonePrompt`; the texts and the state are the controller's (``MicrophoneScreen``).
struct MicrophoneDialogs: ViewModifier {
    let host: CallsHost

    func body(content: Content) -> some View {
        let screen = host.microphoneScreen
        let explain: Bool = { if case .explain? = screen?.prompt { true } else { false } }()
        let blocked: Bool = { if case .blocked? = screen?.prompt { true } else { false } }()
        content
            .confirmDialog(
                isPresented: Binding(get: { explain }, set: { if !$0 { host.closeMicrophonePrompt() } }),
                title: screen?.title ?? "", message: screen?.body ?? "", confirmLabel: screen?.primaryButton ?? "",
                dismissLabel: screen?.secondaryButton, onConfirm: { host.allowMicrophone() }
            )
            .confirmDialog(
                isPresented: Binding(get: { blocked }, set: { if !$0 { host.closeMicrophonePrompt() } }),
                title: screen?.title ?? "", message: screen?.body ?? "", confirmLabel: screen?.primaryButton ?? "",
                dismissLabel: screen?.secondaryButton,
                onConfirm: {
                    host.closeMicrophonePrompt()
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            )
    }
}

/// The calls' own window, above everything the app shows (sheets, full-screen covers and alerts included) and below the app
/// lock's and the privacy shield's: a call keeps only its own screen up over the covered shell (IOS-PLAN §6.6), and a sheet
/// the member had open under it does not hide an incoming call. The app lock is a UI gate only and ends no call (vettid-android):
/// its window covers this one, and the call goes on.
@MainActor
public final class CallsWindow {
    private static var installed: [ObjectIdentifier: CallsWindow] = [:]
    public static let level = UIWindow.Level.alert

    public let window: UIWindow
    private let controller = UIHostingController(rootView: AnyView(EmptyView()))
    private var built = false

    public static func install(on scene: UIWindowScene) -> CallsWindow {
        let id = ObjectIdentifier(scene)
        if let w = installed[id] { return w }
        let w = CallsWindow(scene)
        installed[id] = w
        return w
    }

    private init(_ scene: UIWindowScene) {
        window = UIWindow(windowScene: scene)
        window.windowLevel = Self.level
        window.rootViewController = controller
        controller.view.backgroundColor = .clear
        // Nothing of the app under the call (or the microphone dialog) is read by VoiceOver while it shows.
        controller.view.accessibilityViewIsModal = true
        window.backgroundColor = .clear
        window.isHidden = true
        window.accessibilityIdentifier = "calls_window"
    }

    public var isShown: Bool { !window.isHidden }

    public func show(_ view: AnyView, rebuild: Bool) {
        if !built || rebuild {
            controller.rootView = view
            built = true
        }
        guard window.isHidden else { return }
        // No text field of the app keeps the keyboard: it would sit over the call screen. Only the app's own windows are asked, and a
        // secure field (a PIN or a password being typed, as under the owner check) keeps it.
        Self.resignKeyboard(of: window.windowScene)
        window.isHidden = false
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// The first responder of the app's windows lets go, unless it is a secure text field.
    public static func resignKeyboard(of scene: UIWindowScene?) {
        for w in scene?.windows ?? [] where w.windowLevel < level {
            guard let responder = firstResponder(in: w) else { continue }
            if (responder as? UITextField)?.isSecureTextEntry == true || (responder as? UITextView)?.isSecureTextEntry == true { continue }
            responder.resignFirstResponder()
        }
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for sub in view.subviews { if let found = firstResponder(in: sub) { return found } }
        return nil
    }

    /// While the app lock covers the app VoiceOver does not read the call screen either (as the shell under the lock is not read).
    public func hideFromAccessibility(_ hidden: Bool) { controller.view.accessibilityElementsHidden = hidden }

    public func hide() {
        guard !window.isHidden else { return }
        window.isHidden = true
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
}

extension View {
    /// Presents the calls' window (the call screen, the microphone dialogs) over the app while [host] has anything to show.
    /// [hiddenFromAccessibility]: the app lock covers the app (its window is over this one): VoiceOver reads only the lock.
    public func callsWindow(_ host: CallsHost, themeMode: ThemeMode, hiddenFromAccessibility: Bool = false) -> some View {
        modifier(CallsWindowModifier(host: host, themeMode: themeMode, hidden: hiddenFromAccessibility))
    }
}

private struct CallsWindowModifier: ViewModifier {
    let host: CallsHost
    let themeMode: ThemeMode
    let hidden: Bool
    @State private var scene: UIWindowScene?

    func body(content: Content) -> some View {
        // Read in the body: the window follows the calls' state.
        let shown = host.screenShown
        content
            .background(SceneProbe { scene = $0 }.frame(width: 0, height: 0))
            .onChange(of: shown, initial: true) { _, _ in update() }
            .onChange(of: scene) { _, _ in update() }
            .onChange(of: themeMode) { _, _ in update(rebuild: true) }
            .onChange(of: hidden, initial: true) { _, _ in update() }
    }

    private func update(rebuild: Bool = false) {
        guard let scene else { return }
        let w = CallsWindow.install(on: scene)
        w.hideFromAccessibility(hidden)
        if host.screenShown {
            w.show(AnyView(CallsContent(host: host).vettIDTheme(themeMode)), rebuild: rebuild)
        } else {
            w.hide()
        }
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
        let v = Probe()
        v.found = found
        return v
    }

    func updateUIView(_ view: Probe, context: Context) { view.found = found }
}
#endif
