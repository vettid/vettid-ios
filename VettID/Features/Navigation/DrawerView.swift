import SwiftUI

// MARK: - App Section

enum AppSection: String, CaseIterable {
    case vault = "Vault"
    case vaultServices = "Vault Services"
    case appSettings = "App Settings"

    var icon: String {
        switch self {
        case .vault: return "building.2.fill"
        case .vaultServices: return "cloud.fill"
        case .appSettings: return "gearshape.fill"
        }
    }
}

// MARK: - Drawer View

struct DrawerView: View {
    @Binding var isOpen: Bool
    @Binding var currentSection: AppSection
    let onSignOut: () -> Void

    @EnvironmentObject var appState: AppState
    @State private var showSignOutSheet = false

    private let drawerWidth = UIScreen.main.bounds.width * 0.75

    var body: some View {
        ZStack {
            // Scrim
            if isOpen {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) {
                            isOpen = false
                        }
                    }
            }

            // Drawer
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    // Profile header
                    DrawerHeader()

                    Divider()

                    // Section navigation
                    VStack(spacing: 0) {
                        DrawerItem(
                            icon: AppSection.vault.icon,
                            title: AppSection.vault.rawValue,
                            isSelected: currentSection == .vault
                        ) {
                            currentSection = .vault
                            withAnimation(.spring(response: 0.3)) {
                                isOpen = false
                            }
                        }

                        DrawerItem(
                            icon: AppSection.vaultServices.icon,
                            title: AppSection.vaultServices.rawValue,
                            isSelected: currentSection == .vaultServices
                        ) {
                            currentSection = .vaultServices
                            withAnimation(.spring(response: 0.3)) {
                                isOpen = false
                            }
                        }

                        DrawerItem(
                            icon: AppSection.appSettings.icon,
                            title: AppSection.appSettings.rawValue,
                            isSelected: currentSection == .appSettings
                        ) {
                            currentSection = .appSettings
                            withAnimation(.spring(response: 0.3)) {
                                isOpen = false
                            }
                        }
                    }

                    Divider()
                        .padding(.vertical, 8)

                    // Quick Toggles
                    QuickTogglesSection()

                    Spacer()

                    Divider()

                    // Sign out
                    DrawerItem(
                        icon: "rectangle.portrait.and.arrow.right",
                        title: "Sign Out",
                        isDestructive: true
                    ) {
                        showSignOutSheet = true
                    }

                    // Version info
                    Text("VettID v1.0.0")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding()
                }
                .frame(width: drawerWidth)
                .background(Color(.systemBackground))

                Spacer()
            }
            .offset(x: isOpen ? 0 : -drawerWidth)
        }
        .animation(.spring(response: 0.3), value: isOpen)
        .sheet(isPresented: $showSignOutSheet) {
            SignOutSheet(
                hasActiveVault: appState.hasActiveVault,
                onSignOutVault: {
                    appState.signOut()
                    withAnimation(.spring(response: 0.3)) {
                        isOpen = false
                    }
                },
                onSignOutVaultServices: {
                    appState.fullSignOut()
                    withAnimation(.spring(response: 0.3)) {
                        isOpen = false
                    }
                }
            )
            .presentationDetents([.medium])
        }
    }
}

// MARK: - Quick Toggles Section

struct QuickTogglesSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quick Settings")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            // Theme toggle
            QuickToggleRow(
                icon: appState.theme.icon,
                title: "Theme",
                value: appState.theme.rawValue,
                iconColor: themeIconColor
            ) {
                cycleTheme()
            }

            // Notifications toggle
            QuickToggleRow(
                icon: appState.preferences.notificationsEnabled ? "bell.fill" : "bell.slash.fill",
                title: "Notifications",
                value: appState.preferences.notificationsEnabled ? "On" : "Off",
                iconColor: appState.preferences.notificationsEnabled ? .blue : .gray
            ) {
                var prefs = appState.preferences
                prefs.notificationsEnabled.toggle()
                appState.preferences = prefs
            }
        }
    }

    private var themeIconColor: Color {
        switch appState.theme {
        case .auto: return .purple
        case .light: return .orange
        case .dark: return .indigo
        }
    }

    private func cycleTheme() {
        let themes = AppTheme.allCases
        guard let currentIndex = themes.firstIndex(of: appState.theme) else { return }
        let nextIndex = (currentIndex + 1) % themes.count
        appState.theme = themes[nextIndex]
    }
}

// MARK: - Quick Toggle Row

struct QuickToggleRow: View {
    let icon: String
    let title: String
    let value: String
    let iconColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(iconColor)
                    .frame(width: 24)

                Text(title)
                    .font(.subheadline)

                Spacer()

                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray5))
                    .cornerRadius(8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .foregroundStyle(.primary)
    }
}

// MARK: - Sign Out Sheet

struct SignOutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let hasActiveVault: Bool
    let onSignOutVault: () -> Void
    let onSignOutVaultServices: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Icon
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 50))
                    .foregroundStyle(.orange)
                    .padding(.top, 32)

                // Title
                Text("Sign Out")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Choose how you'd like to sign out")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Options
                VStack(spacing: 12) {
                    if hasActiveVault {
                        SignOutOptionButton(
                            icon: "building.2",
                            title: "Sign out of Vault",
                            description: "Lock your vault but stay signed in to Vault Services",
                            color: .orange
                        ) {
                            dismiss()
                            onSignOutVault()
                        }
                    }

                    SignOutOptionButton(
                        icon: "icloud.and.arrow.up",
                        title: "Sign out of Vault Services",
                        description: "Sign out completely. You'll need to re-authenticate.",
                        color: .red
                    ) {
                        dismiss()
                        onSignOutVaultServices()
                    }
                }
                .padding(.horizontal)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct SignOutOptionButton: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }
}

// MARK: - Drawer Header

struct DrawerHeader: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Avatar
            Image(systemName: "person.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            // User info
            Text(userName)
                .font(.headline)

            if let email = userEmail {
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Vault status indicator
            HStack(spacing: 6) {
                Image(systemName: vaultStatusIcon)
                    .foregroundStyle(vaultStatusColor)
                Text(vaultStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .padding()
        .padding(.top, 20)
    }

    private var userName: String {
        // TODO: Get from stored profile
        "VettID User"
    }

    private var userEmail: String? {
        // TODO: Get from stored profile
        nil
    }

    private var vaultStatusIcon: String {
        appState.hasCredential ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var vaultStatusColor: Color {
        appState.hasCredential ? .green : .orange
    }

    private var vaultStatusText: String {
        appState.hasCredential ? "Vault Active" : "Not Enrolled"
    }
}

// MARK: - Drawer Item

struct DrawerItem: View {
    let icon: String
    let title: String
    var isSelected: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 24)

                Text(title)
                    .font(.body)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        }
        .foregroundStyle(foregroundColor)
    }

    private var foregroundColor: Color {
        if isDestructive {
            return .red
        } else if isSelected {
            return .blue
        } else {
            return .primary
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var isOpen = true
        @State private var section = AppSection.vault

        var body: some View {
            ZStack {
                Color.gray.opacity(0.3)
                    .ignoresSafeArea()

                DrawerView(
                    isOpen: $isOpen,
                    currentSection: $section,
                    onSignOut: {}
                )
            }
            .environmentObject(AppState())
        }
    }

    return PreviewWrapper()
}
