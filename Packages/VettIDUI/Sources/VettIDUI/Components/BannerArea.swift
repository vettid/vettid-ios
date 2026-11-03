import SwiftUI
import UIKit

/// The banner areas on screen, which share a third of the screen between them: one alone may take the third, two take half
/// of it each (the move notices above the app, the banners of the shell). An area counts while it has banners.
@MainActor
@Observable
final class BannerBudget {
    static let shared = BannerBudget()
    private var heights: [UUID: CGFloat] = [:]

    /// [id] has banners [height] high now (0: none).
    func report(_ id: UUID, _ height: CGFloat) {
        if height > 0 { heights[id] = height } else { heights.removeValue(forKey: id) }
    }

    /// How many areas have banners, at least one (the asking one).
    func sharers(including id: UUID) -> Int { max(1, heights.keys.count + (heights[id] == nil ? 1 : 0)) }

    /// An area's limit when [sharers] areas share [third].
    static func limit(third: CGFloat, sharers: Int) -> CGFloat { third / CGFloat(max(1, sharers)) }
}

/// The banners above a screen's content: a plain stack while they fit under the limit (a third of the screen, shared with
/// the other banner area), and a scroll view of the limit's height when they would take more, so that up to eight banners
/// at the largest text size never push the content off the screen (IOS-PLAN ID5). No banner: no height. The scroll view
/// keeps no inset and does not take the status bar's scroll-to-top, which stays with the screen's list.
public struct BannerArea<Content: View>: View {
    private let explicitLimit: CGFloat?
    private let content: Content
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
        return third == 0 ? .infinity : BannerBudget.limit(third: third, sharers: BannerBudget.shared.sharers(including: id))
    }

    public var body: some View {
        let stack = VStack(spacing: 0) { content }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        Group {
            if Self.scrolls(content: contentHeight, limit: limit) {
                // The finder is inside the content, so that the scroll view is among its ancestors.
                ScrollView { stack.background(KeepsScrollToTopForTheScreen()) }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: limit)
            } else {
                stack
            }
        }
        .background {
            if explicitLimit == nil {
                Color.clear
                    .containerRelativeFrame(.vertical) { length, _ in length / 3 }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { third = $0 } }
            }
        }
        .onChange(of: contentHeight) { _, height in BannerBudget.shared.report(id, height) }
        .onDisappear { BannerBudget.shared.report(id, 0) }
    }

    /// Whether banners [content] high need the scroll view under [limit].
    static func scrolls(content: CGFloat, limit: CGFloat) -> Bool { content > limit }
}

/// Placed behind a scroll view's content (inside it): turns off the scroll view's scroll-to-top and its safe-area inset, so that the
/// status bar's tap goes to the screen's own list (UIKit does nothing when two scroll views on screen take it) and the
/// banners add no space at the window's top edge.
struct KeepsScrollToTopForTheScreen: UIViewRepresentable {
    func makeUIView(context: Context) -> Finder { Finder() }
    func updateUIView(_ view: Finder, context: Context) { view.apply() }

    final class Finder: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
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
            scroll.scrollsToTop = false
            scroll.contentInsetAdjustmentBehavior = .never
        }
    }
}
