import SwiftUI
import UIKit

/// The banner areas on screen, which share a third of the screen between them: one alone may take the third, two take half
/// of it each (the move notices above the app, the banners of the shell). An area counts while it has banners.
/// Made once at the scene root and injected with `bannerBudgetRoot(_:)`, like ``InputInProgress``. An area
/// without one gets a fresh instance at each read of the environment: it counts alone and, with no screen height measured,
/// takes what its banners need.
@MainActor
@Observable
public final class BannerBudget {
    private var heights: [UUID: CGFloat] = [:]
    /// The height of the scene's screen, measured once at the root (it changes with the window, a Stage Manager resize).
    var screenHeight: CGFloat = 0

    nonisolated public init() {}

    /// [id] has banners [height] high now (0: none).
    func report(_ id: UUID, _ height: CGFloat) {
        if height > 0 { heights[id] = height } else { heights.removeValue(forKey: id) }
    }

    /// How many areas have banners now.
    var counted: Int { heights.count }

    /// How many areas have banners, at least one (the asking one).
    func sharers(including id: UUID) -> Int { max(1, heights.keys.count + (heights[id] == nil ? 1 : 0)) }

    /// An area's limit when [sharers] areas share [third].
    static func limit(third: CGFloat, sharers: Int) -> CGFloat { third / CGFloat(max(1, sharers)) }
}

public extension EnvironmentValues {
    /// Where the banner areas of a scene share a third of its screen; set at the scene root.
    @Entry var bannerBudget = BannerBudget()
}

public extension View {
    /// Makes [budget] the scene's banner budget and measures the screen for it, once, here: from a background that ignores the safe
    /// area, so that it is the whole window and follows a resize that changes only the height.
    func bannerBudgetRoot(_ budget: BannerBudget) -> some View {
        environment(\.bannerBudget, budget)
            .background {
                // Inside `ignoresSafeArea`, so that the size read is the whole window's, not the safe area's.
                Color.clear
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { budget.screenHeight = $0 }
                    .ignoresSafeArea()
            }
    }
}

/// The banners above a screen's content: a plain stack while they fit under the limit (a third of the screen, shared with
/// the other banner area), and a scroll view of the limit's height when they would take more, so that up to eight banners
/// at the largest text size never push the content off the screen (IOS-PLAN ID5). No banner: no height. The scroll view
/// does not take the status bar's scroll-to-top, which stays with the screen's list.
public struct BannerArea<Content: View>: View {
    private let explicitLimit: CGFloat?
    private let content: Content
    @Environment(\.bannerBudget) private var budget
    @State private var id = UUID()
    @State private var contentHeight: CGFloat = 0

    /// [limit]: the most height the banners take; nil for the shared third of the screen (`bannerBudgetRoot(_:)`; the
    /// banners take what they need until it is measured).
    public init(limit: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        explicitLimit = limit
        self.content = content()
    }

    private var limit: CGFloat {
        if let explicitLimit { return explicitLimit }
        let third = budget.screenHeight / 3
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
                ScrollView { stack.background(KeepsScrollToTopForTheScreen()) }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: limit)
            } else {
                stack
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

/// Placed behind a scroll view's content (inside it): turns off that scroll view's scroll-to-top, so that the status bar's
/// tap goes to the screen's own list (UIKit does nothing when two scroll views on screen take it). It sits inside the
/// area's own scroll view, so the nearest scroll view above it is that one and no other is touched. It applies again at
/// every update and layout, so that a first pass that came before the view was in place does not leave it on.
struct KeepsScrollToTopForTheScreen: UIViewRepresentable {
    func makeUIView(context: Context) -> Finder { Finder() }
    func updateUIView(_ view: Finder, context: Context) { view.apply() }

    final class Finder: UIView {
        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            apply()
        }

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
            (up as? UIScrollView)?.scrollsToTop = false
        }
    }
}
