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

    private func banners(_ count: Int) -> some View {
        ForEach(0..<count, id: \.self) { _ in Color.gray.frame(height: 80) }
    }

    /// [root] in a window of [height], polled up to 2 s until [ready] holds of the scroll views found (the window's
    /// scroll views as last found are returned either way).
    private func scrollViews(
        in root: some View, height: CGFloat = 844, until ready: ([UIScrollView]) -> Bool
    ) async -> [UIScrollView] {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: height))
        window.rootViewController = UIHostingController(rootView: root.vettIDTheme(.light))
        window.isHidden = false
        defer { window.isHidden = true }
        var found: [UIScrollView] = []
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            window.layoutIfNeeded()
            found = Self.views(in: window).compactMap { $0 as? UIScrollView }
            if ready(found) { break }
            try? await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < end
        return found
    }

    /// A stack while the banners fit (no scroll view; the area has counted itself); a scroll view without the status bar's
    /// scroll-to-top when they do not.
    @Test func aBannerAreaScrollsOnlyBeyondItsLimit() async {
        let budget = BannerBudget()
        let fitting = VStack(spacing: 0) { BannerArea { banners(2) }; Color.clear }.bannerBudgetRoot(budget)
        let fits = await scrollViews(in: fitting) { _ in budget.counted == 1 && budget.screenHeight > 0 }
        #expect(budget.counted == 1 && budget.screenHeight > 0 && fits.isEmpty)
        let overflowing = await scrollViews(in: BannerArea(limit: 200) { banners(8) }) { $0.contains { !$0.scrollsToTop } }
        #expect(!overflowing.isEmpty && overflowing.allSatisfy { !$0.scrollsToTop })
        #expect(BannerArea<EmptyView>.scrolls(content: 640, limit: 281) && !BannerArea<EmptyView>.scrolls(content: 90, limit: 281))
    }

    /// Regression: the finder touches only the banner area's own scroll view, the nearest one above it; an outer scroll view
    /// around the area keeps the status bar's tap.
    @Test func anOuterScrollViewIsLeftAlone() async {
        let root = ScrollView { VStack(spacing: 0) { BannerArea(limit: 100) { banners(8) }; Color.clear.frame(height: 2_000) } }
        let found = await scrollViews(in: root) { $0.count >= 2 && $0.contains { !$0.scrollsToTop } }
        #expect(found.filter { !$0.scrollsToTop }.count == 1)
        #expect(found.filter { $0.scrollsToTop }.count == found.count - 1 && found.count >= 2)
    }

    /// The first banner of an overflowing area at the top of the window sits below the safe area (the status bar, the
    /// Dynamic Island): the scroll view adds no inset of its own and does not remove the system's.
    @Test func theFirstBannerOfAnAreaAtTheTopIsBelowTheSafeArea() async {
        final class Box { var minY: CGFloat = -1 }
        let box = Box()
        let first = Color.gray.frame(height: 80)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { box.minY = $0 }
        // At the top of the window, as the shell has it, with a top inset forced (a scene-less window may have none).
        let root = VStack(spacing: 0) { BannerArea(limit: 150) { first; banners(7) }; Color.clear }
        let host = UIHostingController(rootView: root.vettIDTheme(.light))
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 0, right: 0)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while box.minY < 0, ContinuousClock.now < end {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        window.layoutIfNeeded()
        #expect(host.view.safeAreaInsets.top > 0, "the window has a top inset")
        #expect(box.minY >= host.view.safeAreaInsets.top - 0.5, "\(box.minY) vs \(host.view.safeAreaInsets.top)")
        // The area's scroll view keeps the system's inset: its content starts below the inset, not under it.
        let scrolls = Self.views(in: window).compactMap { $0 as? UIScrollView }.filter { !$0.scrollsToTop }
        #expect(scrolls.count == 1)
        for scroll in scrolls {
            #expect(scroll.contentInsetAdjustmentBehavior != .never)
            let adjusted = scroll.adjustedContentInset.top
            #expect(adjusted >= scroll.safeAreaInsets.top - 0.5, "\(adjusted) vs \(scroll.safeAreaInsets.top)")
        }
    }

    /// The production path: two areas with no limit of their own share one budget made at the root, each overflowing, and each
    /// takes a sixth of the window (a third between them).
    @Test func twoDefaultAreasShareAThirdOfTheWindow() async {
        let budget = BannerBudget()
        let root = VStack(spacing: 0) {
            BannerArea { banners(8) }
            BannerArea { banners(8) }
            Color.clear
        }
        .bannerBudgetRoot(budget)
        func settled(_ found: [UIScrollView]) -> Bool {
            found.count == 2 && found.allSatisfy { !$0.scrollsToTop && abs($0.bounds.height - $0.safeAreaInsets.top - 900 / 6) <= 6 }
        }
        let found = await scrollViews(in: root, height: 900, until: settled)
        #expect(settled(found), "\(found.map(\.bounds.height))")
    }

    /// An area that comes back with its state intact (the screen over it closed) counts again.
    @Test func anAreaReturningWithItsStateCountsAgain() async {
        struct Probe: View {
            @Binding var path: [Int]
            var body: some View {
                NavigationStack(path: $path) {
                    VStack(spacing: 0) { BannerArea { Color.gray.frame(height: 80) }; Color.clear }
                        .navigationDestination(for: Int.self) { _ in Color.red }
                }
            }
        }
        let budget = BannerBudget()
        struct Host: View {
            let budget: BannerBudget
            @State var path: [Int] = []
            let push: (Binding<[Int]>) -> Void
            var body: some View { Probe(path: $path).bannerBudgetRoot(budget).onAppear { push($path) } }
        }
        var binding: Binding<[Int]>?
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: Host(budget: budget) { binding = $0 })
        window.isHidden = false
        func wait(_ counted: Int) async -> Bool {
            let end = ContinuousClock.now.advanced(by: .seconds(2))
            while budget.counted != counted, ContinuousClock.now < end {
                window.layoutIfNeeded()
                try? await Task.sleep(for: .milliseconds(50))
            }
            return budget.counted == counted
        }
        #expect(await wait(1))
        binding?.wrappedValue = [1]
        #expect(await wait(0))
        binding?.wrappedValue = []
        #expect(await wait(1))
        window.isHidden = true
    }

    private static func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }
}
