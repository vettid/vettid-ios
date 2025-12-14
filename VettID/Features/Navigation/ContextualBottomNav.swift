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
    case status = 0
    case backups = 1
    case manage = 2

    var title: String {
        switch self {
        case .status: return "Status"
        case .backups: return "Backups"
        case .manage: return "Manage"
        }
    }

    var icon: String {
        switch self {
        case .status: return "chart.bar.fill"
        case .backups: return "externaldrive.fill"
        case .manage: return "slider.horizontal.3"
        }
    }
}

enum AppSettingsNavItem: Int, CaseIterable {
    case theme = 0
    case security = 1
    case about = 2

    var title: String {
        switch self {
        case .theme: return "Theme"
        case .security: return "Security"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .theme: return "paintbrush.fill"
        case .security: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }
}

// MARK: - Contextual Bottom Nav

struct ContextualBottomNav: View {
    let section: AppSection
    @Binding var selectedItem: Int
    var onMoreTap: (() -> Void)? = nil
    var unreadFeedCount: Int = 0
    var pendingConnectionsCount: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            switch section {
            case .vault:
                VaultNav(
                    selectedItem: $selectedItem,
                    onMoreTap: onMoreTap,
                    feedBadge: unreadFeedCount,
                    connectionsBadge: pendingConnectionsCount
                )
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
    var feedBadge: Int = 0
    var connectionsBadge: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(VaultNavItem.allCases, id: \.rawValue) { item in
                NavItem(
                    icon: item.icon,
                    title: item.title,
                    isSelected: selectedItem == item.rawValue,
                    badge: badgeCount(for: item)
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

    private func badgeCount(for item: VaultNavItem) -> Int {
        switch item {
        case .connections: return connectionsBadge
        case .feed: return feedBadge
        case .more: return 0
        }
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
                    selectedItem = item.rawValue
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
                    selectedItem = item.rawValue
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
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 22))

                    // Badge
                    if badge > 0 {
                        BadgeView(count: badge)
                            .offset(x: 8, y: -4)
                    }
                }

                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? .blue : .secondary)
        }
    }
}

// MARK: - Badge View

struct BadgeView: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.red)
            .clipShape(Capsule())
            .minimumScaleFactor(0.8)
    }
}

// MARK: - More Menu Sheet

struct VaultMoreMenuSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void

    var body: some View {
        NavigationView {
            List {
                Section("Personal") {
                    MoreMenuItem(icon: "person.fill", title: "Profile") {
                        onSelect("profile")
                        dismiss()
                    }

                    MoreMenuItem(icon: "lock.fill", title: "Secrets") {
                        onSelect("secrets")
                        dismiss()
                    }

                    MoreMenuItem(icon: "folder.fill", title: "Personal Data") {
                        onSelect("personalData")
                        dismiss()
                    }
                }

                Section("Vault") {
                    MoreMenuItem(icon: "key.fill", title: "Credentials") {
                        onSelect("credentials")
                        dismiss()
                    }

                    MoreMenuItem(icon: "clock.fill", title: "Activity Log") {
                        onSelect("activity")
                        dismiss()
                    }

                    MoreMenuItem(icon: "archivebox.fill", title: "Archive") {
                        onSelect("archive")
                        dismiss()
                    }

                    MoreMenuItem(icon: "gearshape.fill", title: "Preferences") {
                        onSelect("preferences")
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
        .presentationDetents([.medium, .large])
    }
}

struct VaultServicesMoreMenuSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void

    var body: some View {
        NavigationView {
            List {
                Section("Services") {
                    MoreMenuItem(icon: "puzzlepiece.fill", title: "Handlers") {
                        onSelect("handlers")
                        dismiss()
                    }

                    MoreMenuItem(icon: "message.fill", title: "Messaging") {
                        onSelect("messaging")
                        dismiss()
                    }

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
