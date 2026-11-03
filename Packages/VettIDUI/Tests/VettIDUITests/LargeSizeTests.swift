import SwiftUI
import Testing
import UIKit
@testable import VettIDUI

/// The layout at the accessibility sizes (IOS-PLAN ID5): icons follow the text but never outgrow their column, and the
/// banners above a screen are bounded and scroll.
@MainActor
struct LargeSizeTests {
    private func size(_ view: some View, type: DynamicTypeSize = .large) -> CGSize {
        let root = view.environment(\.dynamicTypeSize, type).vettIDTheme(.light)
        return UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: 390, height: 4_000))
    }

    @Test func anIconGrowsWithTheTextAndStopsAtItsCap() {
        let icon = Image(systemName: "lock")
        let usual = size(icon.scaledIcon(size: 20)).height
        let big = size(icon.scaledIcon(size: 20), type: .accessibility5).height
        #expect(big > usual)
        #expect(big <= size(icon.scaledIcon(size: 20 * ScaledIconModifier.capFactor)).height + 1)
        #expect(ScaledIconModifier.capped(30, base: 20) == 30)
        #expect(ScaledIconModifier.capped(100, base: 20) == 20 * ScaledIconModifier.capFactor)
        // The column beside it grows the same way.
        let column = Color.clear.frame(height: 1).scaledIconColumn(24)
        #expect(size(column, type: .accessibility5).width > size(column).width)
        #expect(size(column, type: .accessibility5).width <= 24 * ScaledIconModifier.capFactor + 0.5)
    }

    @Test func theBannersShareAThirdOfTheScreen() {
        #expect(BannerBudget.limit(third: 300, sharers: 1) == 300)
        #expect(BannerBudget.limit(third: 300, sharers: 2) == 150)
        let budget = BannerBudget()
        let a = UUID(), b = UUID()
        #expect(budget.sharers(including: a) == 1)
        budget.report(b, 40)
        #expect(budget.sharers(including: a) == 2)
        budget.report(a, 90)
        #expect(budget.sharers(including: a) == 2)
        budget.report(b, 0)
        #expect(budget.sharers(including: a) == 1)
    }

    /// A stack while the banners fit; a scroll view of the limit's height, without the status bar's scroll-to-top, when they
    /// do not.
    @Test func aBannerAreaScrollsOnlyBeyondItsLimit() async {
        func scrollViews(banners: Int, limit: CGFloat) async -> [UIScrollView] {
            let area = BannerArea(limit: limit) {
                ForEach(0..<banners, id: \.self) { _ in Color.gray.frame(height: 80) }
            }
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = UIHostingController(rootView: area.vettIDTheme(.light))
            window.isHidden = false
            for _ in 0..<8 {
                window.layoutIfNeeded()
                try? await Task.sleep(for: .milliseconds(50))
            }
            let found = Self.views(in: window).compactMap { $0 as? UIScrollView }
            window.isHidden = true
            return found
        }
        #expect(await scrollViews(banners: 2, limit: 200).isEmpty)
        let overflowing = await scrollViews(banners: 8, limit: 200)
        #expect(!overflowing.isEmpty)
        #expect(overflowing.allSatisfy { !$0.scrollsToTop && $0.contentInsetAdjustmentBehavior == .never })
        #expect(BannerArea<EmptyView>.scrolls(content: 640, limit: 281) && !BannerArea<EmptyView>.scrolls(content: 90, limit: 281))
    }

    private static func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }
}
