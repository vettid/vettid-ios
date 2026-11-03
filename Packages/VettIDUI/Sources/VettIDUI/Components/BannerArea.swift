import SwiftUI

/// The banners above a screen's content, in a bounded area: as high as the banners are, but never more than [limit] (by
/// default a third of the screen), and scrolling when they would take more, so that up to eight banners at the largest
/// text size never push the content off the screen (IOS-PLAN ID5). No banner: no height.
public struct BannerArea<Content: View>: View {
    private let explicitLimit: CGFloat?
    private let content: Content
    @State private var measuredLimit: CGFloat = .infinity

    /// [limit]: the most height the banners take; nil for a third of the container (the screen), which is measured once
    /// the area is on screen (the banners take what they need until then).
    public init(limit: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        explicitLimit = limit
        self.content = content()
    }

    public var body: some View {
        BoundedHeight(limit: explicitLimit ?? measuredLimit) {
            ScrollView { VStack(spacing: 0) { content } }.scrollBounceBehavior(.basedOnSize)
        }
        .background {
            if explicitLimit == nil {
                Color.clear
                    .containerRelativeFrame(.vertical) { length, _ in length / 3 }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { measuredLimit = $0 } }
            }
        }
    }
}

/// Lays out its one child (a scroll view) as high as the child wants to be, but not above [limit].
struct BoundedHeight: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let height = Self.height(ideal: ideal.height, limit: limit, offered: proposal.height)
        return CGSize(width: proposal.width ?? ideal.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    /// The height taken: the child's own, at most [limit] and what the parent [offered].
    static func height(ideal: CGFloat, limit: CGFloat, offered: CGFloat?) -> CGFloat {
        min(ideal, max(limit, 0), offered ?? .infinity)
    }
}
