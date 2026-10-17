import SwiftUI

/// The member's theme choice.
public enum ThemeMode: String, CaseIterable, Sendable {
    case system, light, dark

    /// The colour scheme to force, or `nil` to follow the system.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

public extension EnvironmentValues {
    /// The current theme's colours, set by ``SwiftUICore/View/vettIDTheme(_:)``.
    @Entry var vettIDColors: VettIDColors = .dark
}

/// VettID theme: navy surfaces with a single gold accent (dark), white with the
/// same accent (light). Mirrors vettid-android `VettIdTheme`.
struct VettIDThemeModifier: ViewModifier {
    let mode: ThemeMode
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let dark = (mode.colorScheme ?? systemScheme) == .dark
        let colors: VettIDColors = dark ? .dark : .light
        content
            .environment(\.vettIDColors, colors)
            .tint(colors.primary.color)
            .foregroundStyle(colors.onSurface)
            .preferredColorScheme(mode.colorScheme)
    }
}

public extension View {
    /// Applies the VettID theme to this view tree.
    func vettIDTheme(_ mode: ThemeMode = .system) -> some View {
        VettIDFonts.register()
        return modifier(VettIDThemeModifier(mode: mode))
    }
}
