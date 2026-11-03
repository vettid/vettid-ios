import Foundation
import SwiftUI
import Testing
import UIKit
@testable import VettIDUI

/// The "Service" label (IOS-PLAN §4.13): at the trailing end of a list row's line, which stays as high as it is without the
/// label whatever the name's length (the label goes under the line from the accessibility sizes); beside or under a page's
/// name, never cutting either.
@MainActor
struct ServiceLabelTests {
    private func size(_ view: some View, width: CGFloat = 390, type: DynamicTypeSize = .large) -> CGSize {
        let root = view.environment(\.dynamicTypeSize, type).vettIDTheme(.light)
        return UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: width, height: 4_000))
    }

    private func line(_ text: String, _ service: Bool) -> some View {
        ServiceRowLine(service: service) { Text(text).lineLimit(1) }
    }

    @Test func aRowLineCarriesTheLabelAtItsEnd() {
        // Unconstrained, the label adds its width.
        let wide = size(line("Example Bank", true).fixedSize(), width: 10_000).width
        #expect(wide > size(line("Example Bank", false).fixedSize(), width: 10_000).width + 20)
        // A name too long for the row truncates: the line stays in the row's width, one line high (the label's own
        // border may add a few points over a bare line; a row's height is checked below).
        let long = String(repeating: "Example Bank of the Very Long Name ", count: 6)
        for type in [DynamicTypeSize.large, .accessibility5] {
            #expect(size(line(long, true), type: type).width <= 390)
            #expect(size(line(long, true), type: type).height < size(line(long, false), type: type).height * 2)
        }
    }

    @Test func aRowWithTheLabelKeepsItsHeight() {
        let long = String(repeating: "Example Bank ", count: 12)
        let labelled = VettIDListRow(title: long, supporting: "Connected", service: true)
        let plain = VettIDListRow(title: long, supporting: "Connected")
        #expect(size(labelled).height == size(plain).height)
        let second = VettIDListRow(title: "A new vote", supporting: long, supportingService: true)
        #expect(size(second).height == size(plain).height)
    }

    /// From the accessibility sizes the label goes under the line, so the name keeps the whole width.
    @Test func aRowLineStacksTheLabelAtTheAccessibilitySizes() {
        let plain = size(line("Example Bank", false), type: .accessibility3).height
        #expect(size(line("Example Bank", true), type: .accessibility3).height > plain + 10)
        // At the usual size the label is beside the name.
        #expect(size(line("Example Bank", true)).height < size(line("Example Bank", false)).height + 10)
    }

    /// A row's title and second line take two lines at the accessibility sizes, one at the others.
    @Test func aRowShowsTwoLinesAtTheAccessibilitySizes() {
        let long = String(repeating: "Adopt the budget for next year ", count: 8)
        let row = VettIDListRow(title: long, supporting: long)
        let short = VettIDListRow(title: "Short", supporting: "Short")
        #expect(size(row, type: .accessibility3).height > size(short, type: .accessibility3).height + 40)
        #expect(size(row).height == size(short).height)
    }

    @Test func aPageNameStacksTheLabelWhenTooLong() {
        let named = { (text: String, service: Bool) in ServiceNamed(service: service) { Text(text) } }
        // Short: on one line, wider than the name alone.
        let pair = size(named("Example Bank", true).fixedSize(), width: 10_000).width
        #expect(pair > size(named("Example Bank", false).fixedSize(), width: 10_000).width + 20)
        // Too long for one line: the label goes under the name, so the pair is taller than the name alone.
        let long = String(repeating: "Example Bank ", count: 12)
        #expect(size(named(long, true)).height > size(named(long, false)).height)
    }
}
