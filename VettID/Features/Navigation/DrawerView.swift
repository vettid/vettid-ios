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

                    Spacer()

                    Divider()

                    // Sign out
                    DrawerItem(
                        icon: "rectangle.portrait.and.arrow.right",
                        title: "Sign Out",
                        isDestructive: true
                    ) {
                        onSignOut()
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
