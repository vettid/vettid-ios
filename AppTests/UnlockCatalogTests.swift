import SwiftUI
import Testing
import UIKit
@testable import VettID
import VettIDOnboarding
import VettIDUI

/// The unlock entries of the debug screen catalog: one per state, and each renders in both themes.
@MainActor
struct UnlockCatalogTests {
    @Test func everyCatalogStateRenders() {
        #expect(Set(UnlockCatalog.entries.map(\.id)).count == UnlockCatalog.entries.count)
        for mode in [ThemeMode.dark, .light] {
            for entry in UnlockCatalog.entries {
                let host = UIHostingController(rootView: UnlockCatalog.screen(entry).vettIDTheme(mode))
                #expect(host.sizeThatFits(in: CGSize(width: 390, height: 844)).height > 0, "\(entry.id)")
            }
        }
    }
}

/// The owner-check entries of the debug screen catalog: one per state, and each renders in both themes.
@MainActor
struct OwnerCheckCatalogTests {
    @Test func everyCatalogStateRenders() {
        #expect(Set(OwnerCheckCatalog.entries.map(\.id)).count == OwnerCheckCatalog.entries.count)
        for mode in [ThemeMode.dark, .light] {
            for entry in OwnerCheckCatalog.entries {
                let host = UIHostingController(rootView: OwnerCheckCatalog.screen(entry).vettIDTheme(mode))
                #expect(host.sizeThatFits(in: CGSize(width: 390, height: 844)).height > 0, "\(entry.id)")
            }
        }
    }
}
