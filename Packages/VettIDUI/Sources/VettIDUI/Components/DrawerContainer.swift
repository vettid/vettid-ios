import SwiftUI
import UIKit

/// The modal navigation drawer (IOS-PLAN ID14; Material's `ModalNavigationDrawer` as vettid-android's shell uses it):
/// [drawer] slides in from the leading edge over [content] and a scrim. It closes with a tap on the scrim, a swipe
/// towards the edge, VoiceOver's escape gesture, or by the caller (a destination chosen). As on Android, it opens only
/// from the menu button (no edge swipe), so that the edge stays the system back gesture's. While it is open the content
/// takes no touches and VoiceOver reads only the drawer.
public struct DrawerContainer<Drawer: View, Content: View>: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.layoutDirection) private var direction
    @Binding var isOpen: Bool
    let drawer: Drawer
    let content: Content
    @GestureState private var drag: CGFloat = 0

    public init(isOpen: Binding<Bool>, @ViewBuilder drawer: () -> Drawer, @ViewBuilder content: () -> Content) {
        _isOpen = isOpen
        self.drawer = drawer()
        self.content = content()
    }

    public var body: some View {
        GeometryReader { geo in
            let width = min(VettIDDrawerSheet.width, geo.size.width * 0.85)
            ZStack(alignment: .leading) {
                content
                    .allowsHitTesting(!isOpen)
                    .accessibilityHidden(isOpen)
                if isOpen {
                    colors.scrim.color
                        .opacity(Double(1 - min(closing / width, 1)))
                        .ignoresSafeArea()
                        .onTapGesture { isOpen = false }
                        .accessibilityLabel(UIStrings.closeMenu)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { isOpen = false }
                        .transition(.opacity)
                    drawer
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .offset(x: -closing * (direction == .rightToLeft ? -1 : 1))
                        .gesture(closeGesture(width))
                        .accessibilityAddTraits(.isModal)
                        .accessibilityAction(.escape) { isOpen = false }
                        // VoiceOver moves into the drawer once it is in place (the content is hidden from it then), and
                        // back to the content once it has gone.
                        .onAppear { Self.screenChanged() }
                        .onDisappear { Self.screenChanged() }
                        .transition(.move(edge: .leading))
                }
            }
            .animation(.easeOut(duration: 0.25), value: isOpen)
        }
    }

    /// Tells VoiceOver that the screen changed, on the next turn of the main run loop (after the drawer was inserted or
    /// removed).
    private static func screenChanged() {
        DispatchQueue.main.async { UIAccessibility.post(notification: .screenChanged, argument: nil) }
    }

    /// How far the drawer has been dragged back towards its edge.
    private var closing: CGFloat { max(direction == .rightToLeft ? drag : -drag, 0) }

    private func closeGesture(_ width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($drag) { v, state, _ in state = v.translation.width }
            .onEnded { v in
                let back = direction == .rightToLeft ? v.translation.width : -v.translation.width
                if back > width / 3 { isOpen = false }
            }
    }
}

public extension View {
    /// Keeps the system back gesture (the swipe from the leading edge) on the screens of a `NavigationStack` whose bar is
    /// hidden (IOS-PLAN ID14): hiding the bar turns it off, and every VettID screen draws its own back arrow. It only ever
    /// pops a pushed screen, never the stack's root.
    func systemBackGesture() -> some View {
        background(BackGestureEnabler().frame(width: 0, height: 0).accessibilityHidden(true))
    }

    /// Turns the system back gesture off while [blocked] (a pushed screen with unsaved changes, whose back arrow asks
    /// first), and on again when it is not or the screen goes.
    func blocksBackGesture(_ blocked: Bool) -> some View {
        background(BackGestureBlocker(blocked: blocked).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// ``View/blocksBackGesture(_:)``.
private struct BackGestureBlocker: UIViewControllerRepresentable {
    let blocked: Bool

    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ controller: Probe, context: Context) { controller.apply(blocked) }

    final class Probe: UIViewController {
        private var blocked = false

        func apply(_ b: Bool) {
            blocked = b
            navigationController?.interactivePopGestureRecognizer?.isEnabled = !b
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply(blocked)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}

/// Finds the navigation controller of the stack it is placed in and lets its pop gesture begin whenever a screen is
/// pushed, whatever the bar.
private struct BackGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ controller: Probe, context: Context) { controller.attach() }

    final class Probe: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            attach()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            attach()
        }

        func attach() {
            guard let nav = navigationController, let pop = nav.interactivePopGestureRecognizer else { return }
            if !(pop.delegate is PopGestureDelegate) {
                let delegate = PopGestureDelegate(nav)
                objc_setAssociatedObject(nav, &PopGestureDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                pop.delegate = delegate
            }
            pop.isEnabled = true
        }
    }
}

/// Lets the pop gesture begin while a screen is pushed and no transition runs (never on the root, where it would leave the
/// stack stuck).
@MainActor
private final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    private weak var nav: UINavigationController?

    init(_ nav: UINavigationController) {
        self.nav = nav
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Never during a push or pop already under way.
        guard let nav, nav.transitionCoordinator == nil else { return false }
        return nav.viewControllers.count > 1
    }
}
