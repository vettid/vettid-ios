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
                        .announcesAsLayer()
                        .transition(.move(edge: .leading))
                }
            }
            .animation(.easeOut(duration: 0.25), value: isOpen)
        }
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

    /// Turns the system back gestures off while [blocked] (a pushed screen with unsaved changes, whose back arrow asks
    /// first): the edge swipe and, from iOS 26, the swipe from anywhere in the content. On again when it is not, or when
    /// the screen goes. Put it on the screen's outermost view, so that it holds while a step replaces the screen's content.
    func blocksBackGesture(_ blocked: Bool) -> some View {
        background(BackGestureBlocker(blocked: blocked).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// Finds the navigation controller of the stack it is placed in and lets its pop gesture begin whenever a screen is
/// pushed, whatever the bar (``PopGestureDelegate`` decides).
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
            guard let nav = navigationController, PopGestureDelegate.of(nav) != nil else { return }
            nav.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}

/// ``View/blocksBackGesture(_:)``: each probe holds its own block on the stack (``PopGestureDelegate/block(_:by:)``), so
/// that a probe going never clears a block another one holds (a step that replaces the screen's content).
private struct BackGestureBlocker: UIViewControllerRepresentable {
    let blocked: Bool

    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ controller: Probe, context: Context) { controller.apply(blocked) }

    final class Probe: UIViewController {
        private var blocked = false
        /// The stack this probe blocked, to release it there.
        private weak var held: UINavigationController?

        func apply(_ b: Bool) {
            blocked = b
            guard let nav = navigationController ?? held else { return }
            PopGestureDelegate.of(nav)?.block(b, by: self)
            held = b ? nav : nil
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply(blocked)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply(blocked)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            release()
        }

        private func release() {
            if let nav = held { PopGestureDelegate.of(nav)?.block(false, by: self) }
            held = nil
        }

        deinit {
            MainActor.assumeIsolated { release() }
        }
    }
}

/// Lets the back gestures begin while a screen is pushed, no transition runs and no screen holds a block (never on the
/// root, where it would leave the stack stuck): the delegate of the edge swipe. From iOS 26 the swipe from anywhere in the
/// content keeps its own delegate and is turned off while blocked.
@MainActor
final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    private weak var nav: UINavigationController?
    /// The probes that hold a block (a pushed screen with unsaved changes, ``View/blocksBackGesture(_:)``).
    private var holders = Set<ObjectIdentifier>()

    var blocked: Bool { !holders.isEmpty }

    /// [owner] blocks the back gestures, or releases its own block; another owner's block stays.
    func block(_ on: Bool, by owner: AnyObject) {
        if on { holders.insert(ObjectIdentifier(owner)) } else { holders.remove(ObjectIdentifier(owner)) }
        if #available(iOS 26.0, *) { nav?.interactiveContentPopGestureRecognizer?.isEnabled = !blocked }
    }

    init(_ nav: UINavigationController) {
        self.nav = nav
    }

    /// [nav]'s delegate, installed on first use; nil when the stack has no pop gesture.
    static func of(_ nav: UINavigationController) -> PopGestureDelegate? {
        if let d = objc_getAssociatedObject(nav, &key) as? PopGestureDelegate { return d }
        guard let pop = nav.interactivePopGestureRecognizer else { return nil }
        let d = PopGestureDelegate(nav)
        objc_setAssociatedObject(nav, &key, d, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        pop.delegate = d
        return d
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Never during a push or pop already under way, nor from the root, nor while the screen on top blocks it.
        guard !blocked, let nav, nav.transitionCoordinator == nil else { return false }
        return nav.viewControllers.count > 1
    }
}
