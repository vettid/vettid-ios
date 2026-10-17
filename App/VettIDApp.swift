import SwiftUI
import VettIDUI

@main
struct VettIDApp: App {
    @State private var themeMode: ThemeMode = Self.initialThemeMode

    private static var initialThemeMode: ThemeMode {
        #if DEBUG
        // Debug builds: `-vettid.theme dark|light` at launch (screenshots).
        if let mode = UserDefaults.standard.string(forKey: "vettid.theme").flatMap(ThemeMode.init(rawValue:)) {
            return mode
        }
        #endif
        return .system
    }

    var body: some Scene {
        WindowGroup {
            RootView(environment: .current, themeMode: $themeMode)
                .vettIDTheme(themeMode)
        }
    }
}

/// Placeholder until the screens of IOS-PLAN §4 arrive. Debug builds can open the debug catalog from it.
struct RootView: View {
    let environment: AppEnvironment
    @Binding var themeMode: ThemeMode
    @Environment(\.vettIDColors) private var colors

    var body: some View {
        #if DEBUG
        DebugCatalog(themeMode: $themeMode) { skeleton }
        #else
        skeleton
        #endif
    }

    private var skeleton: some View {
        VStack(spacing: Spacing.l) {
            RookLogo(height: 72)
            Text(verbatim: environment.kind.rawValue)
                .vettIDFont(.bodyMedium)
                .foregroundStyle(colors.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.background)
    }
}
