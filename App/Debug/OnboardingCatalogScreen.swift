#if DEBUG
import SwiftUI
import VettIDOnboardingUI
import VettIDUI

/// Debug-only: the onboarding screens in each of their states (``OnboardingCatalog``), with actions that do nothing.
/// Opened from the screen catalog, or at launch with `-vettid.start onboarding`.
struct OnboardingCatalogScreen: View {
    let onBack: @MainActor () -> Void
    @State private var shown: String?

    var body: some View {
        DetailScaffold(onBack: onBack) {
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle("Onboarding")
                    SettingsGroup {
                        ForEach(OnboardingCatalog.entries) { entry in
                            SettingsRow(entry.title) { shown = entry.id }
                                .accessibilityIdentifier("catalog_onboarding_\(entry.id)")
                        }
                    }
                }
            }
        }
        .navigationDestination(item: $shown) { id in
            if let entry = OnboardingCatalog.entries.first(where: { $0.id == id }) {
                OnboardingCatalog.screen(entry)
                    .overlay(alignment: .topTrailing) {
                        IconButton(.close, label: "Close") { shown = nil }.padding(.horizontal, Spacing.xs)
                    }
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}
#endif
