import SwiftUI
import Testing
import UIKit
@testable import VettID
import VettIDOnboarding
import VettIDUI

/// The onboarding entries of the debug screen catalog: one per state, every step of the flow covered, and each renders
/// in both themes.
@MainActor
struct OnboardingCatalogTests {
    @Test func everyCatalogStateRenders() {
        #expect(Set(OnboardingCatalog.entries.map(\.id)).count == OnboardingCatalog.entries.count)
        let shown = Set(OnboardingCatalog.entries.map(\.state.step))
        let routed: Set<OnboardingStep> = [.recover, .transferIn]
        #expect(shown == Set(OnboardingStep.allCases).subtracting(routed), "every step of this flow has a catalog entry")
        for mode in [ThemeMode.dark, .light] {
            for entry in OnboardingCatalog.entries {
                let host = UIHostingController(rootView: OnboardingCatalog.screen(entry).vettIDTheme(mode))
                #expect(host.sizeThatFits(in: CGSize(width: 390, height: 844)).height > 0, "\(entry.id)")
            }
        }
    }
}
