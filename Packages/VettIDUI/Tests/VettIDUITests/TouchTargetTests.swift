import SwiftUI
import Testing
import UIKit
@testable import VettIDUI

/// Controls drawn small are hit over at least 44 pt (IOS-PLAN ID5; Apple's HIG), and a plain text button is hit over its
/// whole frame, not only over its text.
@MainActor
struct TouchTargetTests {
    private func size(_ view: some View, type: DynamicTypeSize = .large) -> CGSize {
        let root = view.environment(\.dynamicTypeSize, type).vettIDTheme(.light)
        return UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: 390, height: 4_000))
    }

    @Test func chipsAreAtLeastAsTallAsATarget() {
        #expect(size(VettIDFilterChip("Work", selected: false) {}).height >= Spacing.minTarget)
        #expect(size(VettIDFilterChip("Work", selected: true) {}).height >= Spacing.minTarget)
        #expect(size(ClearFiltersChip {}).height >= Spacing.minTarget)
        #expect(size(RemovableTagChip("travel", tag: "travel", removeLabel: "Remove tag travel") {}).height >= Spacing.minTarget)
        #expect(Spacing.minTarget == 44)
    }

    @Test func aTextButtonIsATargetHighAtEverySize() {
        for type in [DynamicTypeSize.large, .accessibility5] {
            let button = Button {} label: { Text("Try again").textButtonTarget() }.buttonStyle(.plain)
            #expect(size(button, type: type).height >= Spacing.touchTarget)
        }
    }

    /// A frame outside a plain button leaves the hit area at its text: no site puts one there (the frame and the content
    /// shape go inside the label, ``View/textButtonTarget()``).
    @Test func noPlainButtonHasItsTargetOutsideItsLabel() throws {
        let packages = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: packages, includingPropertiesForKeys: nil))
        let pattern = try NSRegularExpression(
            pattern: #"\.buttonStyle\(\.plain\)\n\s*\.frame\(minHeight: Spacing\.(touchTarget|minTarget)\)"#
        )
        var sites: [String] = []
        for case let url as URL in files
        where url.pathExtension == "swift" && url.path.contains("/Sources/") && !url.path.contains("/.build/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { sites.append(url.lastPathComponent) }
        }
        #expect(sites.isEmpty, "\(sites)")
    }
}
