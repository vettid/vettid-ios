#if DEBUG
import SwiftUI
import VettIDUI

/// Debug-only screen catalog (vettid-android `app/src/debugTools/…/ScreenCatalog.kt`): every screen with sample state,
/// to look at each state and for screenshots; as screens arrive they are added here. Opened from a button on the root screen, or at
/// launch with `-vettid.start gallery` (Android's `vettid.start` launch extra). It is presented over the root, in a
/// navigation stack of its own, so that the root's own stacks (the shell's) are never nested in it. Debug and DevStack
/// builds only; the release check refuses its strings.
struct DebugCatalog<Root: View>: View {
    @Binding var themeMode: ThemeMode
    @ViewBuilder let root: () -> Root
    @State private var path: [DebugCatalogEntry] = DebugCatalogEntry.atLaunch.flatMap { $0 == .catalog ? nil : [$0] } ?? []
    @State private var open = DebugCatalogEntry.atLaunch != nil
    @Environment(\.vettIDColors) private var colors

    var body: some View {
        root()
            .overlay(alignment: .bottomTrailing) {
                SecondaryButton("Screen catalog") {
                    path = []
                    open = true
                }
                .fixedSize()
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.xxl)
            }
            .fullScreenCover(isPresented: $open) {
                NavigationStack(path: $path) {
                    destination(.catalog)
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationDestination(for: DebugCatalogEntry.self) { entry in
                            destination(entry).toolbar(.hidden, for: .navigationBar)
                        }
                }
                .environment(\.vettIDColors, colors)
            }
    }

    /// Back from a screen of the catalog; from the catalog itself, back to the app.
    private func back() {
        if path.isEmpty { open = false } else { path.removeLast() }
    }

    @ViewBuilder
    private func destination(_ entry: DebugCatalogEntry) -> some View {
        switch entry {
        case .catalog:
            DetailScaffold(onBack: back) {
                ScrollView {
                    VStack(spacing: 0) {
                        LargeTitle("Screen catalog")
                        SettingsGroup {
                            SettingsRow("Component gallery", icon: .settings) { path.append(.gallery) }
                            SettingsRow("Onboarding", icon: .key) { path.append(.onboarding) }
                            SettingsRow("Unlock", icon: .lock) { path.append(.unlock) }
                            SettingsRow("Owner check and app lock", icon: .verifiedUser) { path.append(.ownerCheck) }
                            SettingsRow("Shell and settings", icon: .menu) { path.append(.shell) }
                        }
                    }
                }
            }
        case .gallery:
            GalleryScreen(themeMode: $themeMode) { back() }
        case .onboarding:
            OnboardingCatalogScreen { back() }
        case .unlock:
            UnlockCatalogScreen { back() }
        case .ownerCheck:
            OwnerCheckCatalogScreen { back() }
        case .shell:
            ShellCatalogScreen { back() }
        }
    }
}

/// A screen of the debug catalog.
enum DebugCatalogEntry: String, Hashable, CaseIterable {
    case catalog, gallery, onboarding, unlock, ownerCheck, shell

    /// The screen named by the `vettid.start` launch argument, if any.
    static var atLaunch: DebugCatalogEntry? {
        UserDefaults.standard.string(forKey: "vettid.start").flatMap(DebugCatalogEntry.init(rawValue:))
    }
}
#endif
