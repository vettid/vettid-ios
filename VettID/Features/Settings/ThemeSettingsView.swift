import SwiftUI

struct ThemeSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            Section {
                ForEach(AppTheme.allCases, id: \.rawValue) { theme in
                    ThemeOptionRow(
                        theme: theme,
                        isSelected: appState.theme == theme
                    ) {
                        withAnimation {
                            appState.theme = theme
                        }
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Choose how VettID looks. Auto will match your system settings.")
            }

            Section("Preview") {
                ThemePreviewCard(theme: appState.theme)
            }
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Theme Option Row

struct ThemeOptionRow: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    Circle()
                        .fill(iconBackgroundColor)
                        .frame(width: 40, height: 40)

                    Image(systemName: theme.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(iconColor)
                }

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.rawValue)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(theme.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Checkmark
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconBackgroundColor: Color {
        switch theme {
        case .auto: return .purple.opacity(0.15)
        case .light: return .orange.opacity(0.15)
        case .dark: return .indigo.opacity(0.15)
        }
    }

    private var iconColor: Color {
        switch theme {
        case .auto: return .purple
        case .light: return .orange
        case .dark: return .indigo
        }
    }
}

// MARK: - Theme Preview Card

struct ThemePreviewCard: View {
    let theme: AppTheme

    var body: some View {
        VStack(spacing: 0) {
            // Mock header
            HStack {
                Circle()
                    .fill(previewSecondaryColor)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(previewPrimaryColor)
                        .frame(width: 80, height: 10)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(previewSecondaryColor)
                        .frame(width: 60, height: 8)
                }

                Spacer()

                Circle()
                    .fill(previewAccentColor)
                    .frame(width: 24, height: 24)
            }
            .padding()
            .background(previewBackgroundColor)

            Divider()
                .background(previewSecondaryColor)

            // Mock content
            VStack(spacing: 12) {
                ForEach(0..<3) { _ in
                    HStack {
                        Circle()
                            .fill(previewSecondaryColor)
                            .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(previewPrimaryColor)
                                .frame(width: 100, height: 10)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(previewSecondaryColor)
                                .frame(width: 150, height: 8)
                        }

                        Spacer()
                    }
                }
            }
            .padding()
            .background(previewBackgroundColor)

            // Mock bottom nav
            HStack {
                ForEach(0..<3) { index in
                    Spacer()
                    VStack(spacing: 4) {
                        Circle()
                            .fill(index == 0 ? previewAccentColor : previewSecondaryColor)
                            .frame(width: 24, height: 24)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(index == 0 ? previewAccentColor : previewSecondaryColor)
                            .frame(width: 30, height: 6)
                    }
                    Spacer()
                }
            }
            .padding(.vertical, 12)
            .background(previewBackgroundColor)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(previewSecondaryColor, lineWidth: 1)
        )
    }

    private var previewBackgroundColor: Color {
        switch theme {
        case .auto:
            return Color(.systemBackground)
        case .light:
            return .white
        case .dark:
            return Color(white: 0.1)
        }
    }

    private var previewPrimaryColor: Color {
        switch theme {
        case .auto:
            return Color(.label)
        case .light:
            return .black.opacity(0.8)
        case .dark:
            return .white.opacity(0.9)
        }
    }

    private var previewSecondaryColor: Color {
        switch theme {
        case .auto:
            return Color(.secondaryLabel)
        case .light:
            return .black.opacity(0.3)
        case .dark:
            return .white.opacity(0.3)
        }
    }

    private var previewAccentColor: Color {
        .blue
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ThemeSettingsView()
    }
    .environmentObject(AppState())
}
