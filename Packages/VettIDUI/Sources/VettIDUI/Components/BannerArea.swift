import SwiftUI
import UIKit

/// The banner areas on screen, which share a third of the screen between them: one alone may take the third, two take half
/// of it each (the move notices above the app, the banners of the shell). An area counts while it has banners.
/// Made once at the scene root and injected (``EnvironmentValues/bannerBudget``), like ``InputInProgress``; a screen or a test
/// without one has the default instance of its own.
@MainActor
@Observable
public final class BannerBudget {
    private var heights: [UUID: CGFloat] = [:]

    nonisolated public init() {}

    /// [id] has banners [height] high now (0: none).
    func report(_ id: UUID, _ height: CGFloat) {
        if height > 0 { heights[id] = height } else { heights.removeValue(forKey: id) }
    }

    /// How many areas have banners, at least one (the asking one).
    func sharers(including id: UUID) -> Int { max(1, heights.keys.count + (heights[id] == nil ? 1 : 0)) }

    /// An area's limit when [sharers] areas share [third].
    static func limit(third: CGFloat, sharers: Int) -> CGFloat { third / CGFloat(max(1, sharers)) }
}

public extension EnvironmentValues {
    /// Where the banner areas of a scene share a third of its screen; set at the scene root.
    @Entry var bannerBudget = BannerBudget()
}

/// The banners above a screen's content: a plain stack while they fit under the limit (a third of the screen, shared with
/// the other banner area), and a scroll view of the limit's height when they would take more, so that up to eight banners
/// at the largest text size never push the content off the screen (IOS-PLAN ID5). No banner: no height. The scroll view
/// keeps no inset and does not take the status bar's scroll-to-top, which stays with the screen's list.
public struct BannerArea<Content: View>: View {
    private let explicitLimit: CGFloat?
    private let content: Content
    @Environment(\.bannerBudget) private var budget
    @State private var id = UUID()
    @State private var contentHeight: CGFloat = 0
    @State private var third: CGFloat = 0

    /// [limit]: the most height the banners take; nil for the shared third of the container (the screen), measured once the
    /// area is on screen (the banners take what they need until then).
    public init(limit: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        explicitLimit = limit
        self.content = content()
    }

    private var limit: CGFloat {
        if let explicitLimit { return explicitLimit }
        return third == 0 ? .infinity : BannerBudget.limit(third: third, sharers: budget.sharers(including: id))
    }

    public var body: some View {
        let stack = VStack(spacing: 0) { content }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        Group {
            if Self.scrolls(content: contentHeight, limit: limit) {
                // The stack and the scroll view are swapped as the banners grow past the limit or shrink: they are rebuilt, and
                // VoiceOver focus may move then (no banner has state or speaks when it appears).
                // The finder is inside the content, so that the scroll view is among its ancestors.
                ScrollView { stack.background(KeepsScrollToTopForTheScreen(height: limit)) }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: limit)
            } else {
                stack
            }
        }
        .background {
            if explicitLimit == nil {
                WindowHeightReader { height in if height > 0 { third = height / 3 } }
            }
        }
        // An area that comes back with its state intact counts again (the pattern of ``InputInProgress``); a fixed limit
        // takes no part in the sharing.
        .onChange(of: contentHeight, initial: true) { _, height in report(height) }
        .onAppear { report(contentHeight) }
        .onDisappear { report(0) }
    }

    private func report(_ height: CGFloat) {
        if explicitLimit == nil { budget.report(id, height) }
    }

    /// Whether banners [content] high need the scroll view under [limit].
    static func scrolls(content: CGFloat, limit: CGFloat) -> Bool { content > limit }
}

/// Placed behind a scroll view's content (inside it): turns off the scroll view's scroll-to-top and its safe-area inset, so that the
/// status bar's tap goes to the screen's own list (UIKit does nothing when two scroll views on screen take it) and the
/// banners add no space at the window's top edge.
/// Only the banner area's own scroll view, which is [height] high (within a point), is touched; the nearest scroll view of
/// another height is left alone.
struct KeepsScrollToTopForTheScreen: UIViewRepresentable {
    let height: CGFloat

    func makeUIView(context: Context) -> Finder { Finder(height: height) }
    func updateUIView(_ view: Finder, context: Context) {
        view.height = height
        view.apply()
    }

    final class Finder: UIView {
        var height: CGFloat
        private var retries = 0

        init(height: CGFloat) {
            self.height = height
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            apply()
        }

        /// The nearest scroll view above this view.
        func apply() {
            var up: UIView? = superview
            while let view = up, !(view is UIScrollView) { up = view.superview }
            guard let scroll = up as? UIScrollView else { return }
            // Not laid out yet: look again on the next turn (a few times).
            guard scroll.bounds.height > 0 else {
                if retries < 5 {
                    retries += 1
                    DispatchQueue.main.async { [weak self] in self?.apply() }
                }
                return
            }
            // A scroll view at the edge of the window reaches into the safe area: that part is not the area's height.
            let inside = scroll.bounds.height - scroll.safeAreaInsets.top - scroll.safeAreaInsets.bottom
            guard abs(inside - height) <= 1 else { return }
            scroll.scrollsToTop = false
            scroll.contentInsetAdjustmentBehavior = .never
        }
    }
}

/// Reports the height of the window the view is in (the same for every banner area of the scene) when it is put there and
/// when it changes (a turn of the phone, a split view).
struct WindowHeightReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> Reader { Reader(onChange: onChange) }
    func updateUIView(_ view: Reader, context: Context) { view.onChange = onChange }

    final class Reader: UIView {
        var onChange: (CGFloat) -> Void
        private var last: CGFloat = 0

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            guard let height = window?.bounds.height, height != last else { return }
            last = height
            DispatchQueue.main.async { [onChange] in onChange(height) }
        }
    }
}
