#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import VettIDUI

/// An info row's value is never cut (I4 audit, accessibility): a fingerprint a member compares is shown in full at every
/// text size, where a tappable row's description keeps its two lines.
@MainActor
@Suite struct InfoRowTests {
    private let long = String(repeating: "01234567 89abcdef ", count: 8)

    private func height(_ view: some View, _ size: DynamicTypeSize = .large) -> CGFloat {
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size).vettIDTheme(.light))
        return host.sizeThatFits(in: CGSize(width: 320, height: 4000)).height
    }

    @Test func anInfoRowShowsItsWholeValue() {
        let short = height(SettingsInfoRow("Release", value: "01234567", icon: .key, code: true))
        let full = height(SettingsInfoRow("Release", value: long, icon: .key, code: true))
        let plain = height(SettingsInfoRow("Release", value: long, icon: .key))
        // Eight groups pairs at 320 pt need more than two lines: the row grows with them, monospaced or not.
        #expect(full > short + 60 && plain > short + 40)
    }

    @Test func aTappableRowsDescriptionKeepsItsTwoLines() {
        let one = height(SettingsRow("Release", icon: .key, supporting: "01234567", action: {}))
        let many = height(SettingsRow("Release", icon: .key, supporting: long, action: {}))
        #expect(many < one + 40)
    }
}
#endif
