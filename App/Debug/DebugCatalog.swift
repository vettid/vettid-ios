#if DEBUG
import SwiftUI
import VettIDUI

/// Debug-only screen catalog (vettid-android `app/src/debugTools/…/ScreenCatalog.kt`): every screen with sample state,
/// for review and screenshots; for now the component gallery, as screens arrive they are added here. Opened from a
/// button on the root screen, or at launch with `-vettid.start gallery` (Android's `vettid.start` launch extra).
/// Debug and DevStack builds only; the release check refuses its strings.
struct DebugCatalog<Root: View>: View {
    @Binding var themeMode: ThemeMode
    @ViewBuilder let root: () -> Root
    @State private var path: [DebugCatalogEntry] = DebugCatalogEntry.atLaunch.map { [$0] } ?? []
    @Environment(\.vettIDColors) private var colors

    var body: some View {
        NavigationStack(path: $path) {
            root()
                .overlay(alignment: .bottom) {
                    SecondaryButton("Screen catalog") { path = [.catalog] }
                        .padding(Spacing.xl)
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: DebugCatalogEntry.self) { entry in
                    destination(entry).toolbar(.hidden, for: .navigationBar)
                }
        }
    }

    @ViewBuilder
    private func destination(_ entry: DebugCatalogEntry) -> some View {
        switch entry {
        case .catalog:
            DetailScaffold(onBack: { path.removeLast() }) {
                ScrollView {
                    VStack(spacing: 0) {
                        LargeTitle("Screen catalog")
                        SettingsGroup {
                            SettingsRow("Component gallery", icon: .settings) { path.append(.gallery) }
                            SettingsRow("Onboarding", icon: .key) { path.append(.onboarding) }
                        }
                    }
                }
            }
        case .gallery:
            GalleryScreen(themeMode: $themeMode) { path.removeLast() }
        case .onboarding:
            OnboardingCatalogScreen { path.removeLast() }
        }
    }
}

/// A screen of the debug catalog.
enum DebugCatalogEntry: String, Hashable, CaseIterable {
    case catalog, gallery, onboarding

    /// The screen named by the `vettid.start` launch argument, if any.
    static var atLaunch: DebugCatalogEntry? {
        UserDefaults.standard.string(forKey: "vettid.start").flatMap(DebugCatalogEntry.init(rawValue:))
    }
}
#endif
