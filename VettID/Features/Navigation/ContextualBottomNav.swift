import SwiftUI

// MARK: - Nav Item Definitions

enum VaultNavItem: Int, CaseIterable {
    case connections = 0
    case feed = 1
    case more = 2

    var title: String {
        switch self {
        case .connections: return "Connections"
        case .feed: return "Feed"
        case .more: return "More"
        }
    }

    var icon: String {
        switch self {
        case .connections: return "person.2.fill"
        case .feed: return "list.bullet.rectangle"
        case .more: return "ellipsis"
        }
    }
}

enum VaultServicesNavItem: Int, CaseIterable {
    case handlers = 0
    case backups = 1
    case messaging = 2
    case more = 3

    var title: String {
        switch self {
        case .handlers: return "Handlers"
        case .backups: return "Backups"
        case .messaging: return "Messaging"
        case .more: return "More"
        }
    }

    var icon: String {
        switch self {
        case .handlers: return "puzzlepiece.fill"
        case .backups: return "externaldrive.fill"
        case .messaging: return "message.fill"
        case .more: return "ellipsis"
        }
    }
}

enum AppSettingsNavItem: Int, CaseIterable {
    case profile = 0
    case secrets = 1
    case personalData = 2
    case more = 3

    var title: String {
        switch self {
        case .profile: return "Profile"
        case .secrets: return "Secrets"
        case .personalData: return "Data"
        case .more: return "More"
        }
    }

    var icon: String {
        switch self {
        case .profile: return "person.fill"
        case .secrets: return "lock.fill"
        case .personalData: return "folder.fill"
        case .more: return "ellipsis"
        }
    }
}

// MARK: - Contextual Bottom Nav

struct ContextualBottomNav: View {
    let section: AppSection
    @Binding var selectedItem: Int
    var onMoreTap: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            switch section {
            case .vault:
                VaultNav(selectedItem: $selectedItem, onMoreTap: onMoreTap)
            case .vaultServices:
                VaultServicesNav(selectedItem: $selectedItem, onMoreTap: onMoreTap)
            case .appSettings:
                AppSettingsNav(selectedItem: $selectedItem, onMoreTap: onMoreTap)
            }
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Vault Nav

struct VaultNav: View {
    @Binding var selectedItem: Int
    var onMoreTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(VaultNavItem.allCases, id: \.rawValue) { item in
                NavItem(
                    icon: item.icon,
                    title: item.title,
                    isSelected: selectedItem == item.rawValue
                ) {
                    if item == .more {
                        onMoreTap?()
                    } else {
                        selectedItem = item.rawValue
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - Vault Services Nav

struct VaultServicesNav: View {
    @Binding var selectedItem: Int
    var onMoreTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(VaultServicesNavItem.allCases, id: \.rawValue) { item in
                NavItem(
                    icon: item.icon,
                    title: item.title,
                    isSelected: selectedItem == item.rawValue
                ) {
                    if item == .more {
                        onMoreTap?()
                    } else {
                        selectedItem = item.rawValue
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - App Settings Nav

struct AppSettingsNav: View {
    @Binding var selectedItem: Int
    var onMoreTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppSettingsNavItem.allCases, id: \.rawValue) { item in
                NavItem(
                    icon: item.icon,
                    title: item.title,
                    isSelected: selectedItem == item.rawValue
                ) {
                    if item == .more {
                        onMoreTap?()
                    } else {
                        selectedItem = item.rawValue
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - Nav Item

struct NavItem: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))

                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? .blue : .secondary)
        }
    }
}

// MARK: - More Menu Sheet

struct VaultMoreMenuSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void

    var body: some View {
        NavigationView {
            List {
                Section("Vault") {
                    MoreMenuItem(icon: "key.fill", title: "Credentials") {
                        onSelect("credentials")
                        dismiss()
                    }

                    MoreMenuItem(icon: "clock.fill", title: "Activity Log") {
                        onSelect("activity")
                        dismiss()
                    }
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct VaultServicesMoreMenuSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void

    var body: some View {
        NavigationView {
            List {
                Section("Services") {
                    MoreMenuItem(icon: "network", title: "NATS Connection") {
                        onSelect("nats")
                        dismiss()
                    }

                    MoreMenuItem(icon: "heart.fill", title: "Vault Health") {
                        onSelect("health")
                        dismiss()
                    }
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct AppSettingsMoreMenuSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void

    var body: some View {
        NavigationView {
            List {
                Section("Settings") {
                    MoreMenuItem(icon: "bell.fill", title: "Notifications") {
                        onSelect("notifications")
                        dismiss()
                    }

                    MoreMenuItem(icon: "paintbrush.fill", title: "Appearance") {
                        onSelect("appearance")
                        dismiss()
                    }

                    MoreMenuItem(icon: "lock.shield.fill", title: "Security") {
                        onSelect("security")
                        dismiss()
                    }
                }

                Section("About") {
                    MoreMenuItem(icon: "questionmark.circle.fill", title: "Help & Support") {
                        onSelect("help")
                        dismiss()
                    }

                    MoreMenuItem(icon: "hand.raised.fill", title: "Privacy Policy") {
                        onSelect("privacy")
                        dismiss()
                    }
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct MoreMenuItem: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Spacer()

        ContextualBottomNav(
            section: .vault,
            selectedItem: .constant(0)
        )

        Spacer()

        ContextualBottomNav(
            section: .vaultServices,
            selectedItem: .constant(0)
        )

        Spacer()

        ContextualBottomNav(
            section: .appSettings,
            selectedItem: .constant(0)
        )
    }
}
