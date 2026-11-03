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

    @Test func aBannerAreaIsBoundedAndScrollsBeyondItsLimit() {
        func areaHeight(banners: Int, limit: CGFloat) -> CGFloat {
            let area = BannerArea(limit: limit) {
                ForEach(0..<banners, id: \.self) { _ in Color.gray.frame(height: 80) }
            }
            let renderer = ImageRenderer(content: area.vettIDTheme(.light))
            renderer.proposedSize = ProposedViewSize(width: 390, height: 844)
            return renderer.uiImage?.size.height ?? -1
        }

        #expect(areaHeight(banners: 0, limit: 200) <= 0)
        #expect(areaHeight(banners: 2, limit: 200) == 160)
        #expect(areaHeight(banners: 8, limit: 200) == 200)
    }

    @Test func theBoundedHeightTakesTheLeastOfTheChildTheLimitAndTheOffer() {
        #expect(BoundedHeight.height(ideal: 640, limit: 281, offered: 844) == 281)
        #expect(BoundedHeight.height(ideal: 90, limit: 281, offered: 844) == 90)
        #expect(BoundedHeight.height(ideal: 640, limit: 281, offered: 100) == 100)
        #expect(BoundedHeight.height(ideal: 90, limit: .infinity, offered: nil) == 90)
    }
}
