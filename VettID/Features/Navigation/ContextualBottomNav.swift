import SwiftUI

// MARK: - Bottom Nav Item

enum BottomNavItem: Int, CaseIterable {
    case feed = 0
    case connections = 1
    case voting = 2
    case secrets = 3
    case more = 4

    var title: String {
        switch self {
        case .feed: return "Feed"
        case .connections: return "Connections"
        case .voting: return "Voting"
        case .secrets: return "Secrets"
        case .more: return "More"
        }
    }

    var icon: String {
        switch self {
        case .feed: return "list.bullet.rectangle"
        case .connections: return "person.2.fill"
        case .voting: return "checkmark.square.fill"
        case .secrets: return "lock.fill"
        case .more: return "ellipsis"
        }
    }

    /// Corresponding DrawerItem (nil for "More")
    var drawerItem: DrawerItem? {
        switch self {
        case .feed: return .feed
        case .connections: return .connections
        case .voting: return .voting
        case .secrets: return .secrets
        case .more: return nil
        }
    }
}

// MARK: - Bottom Navigation Bar

struct BottomNavBar: View {
    @Binding var currentItem: DrawerItem
    @ObservedObject var badgeCounts: BadgeCountsViewModel
    var onMoreTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 0) {
                ForEach(BottomNavItem.allCases, id: \.rawValue) { tab in
                    NavItem(
                        icon: tab.icon,
                        title: tab.title,
                        isSelected: isTabSelected(tab),
                        badge: badgeForTab(tab)
                    ) {
                        if tab == .more {
                            onMoreTap()
                        } else if let drawerItem = tab.drawerItem {
                            currentItem = drawerItem
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.bottom, 4)
        }
        .background(Color(.systemBackground))
    }

    private func isTabSelected(_ tab: BottomNavItem) -> Bool {
        if let drawerItem = tab.drawerItem {
            return currentItem == drawerItem
        }
        // "More" is selected when viewing personalData or archive
        return !currentItem.isInBottomNav
    }

    private func badgeForTab(_ tab: BottomNavItem) -> Int {
        switch tab {
        case .feed: return badgeCounts.unreadFeedCount
        case .connections: return badgeCounts.pendingConnectionsCount
        case .voting: return badgeCounts.unvotedProposalsCount
        case .secrets, .more: return 0
        }
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

struct MoreMenuSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (DrawerItem) -> Void

    var body: some View {
        NavigationView {
            List {
                Section("Features") {
                    MoreMenuItem(icon: DrawerItem.personalData.icon, title: DrawerItem.personalData.title) {
                        onSelect(.personalData)
                        dismiss()
                    }

                    MoreMenuItem(icon: DrawerItem.archive.icon, title: DrawerItem.archive.title) {
                        onSelect(.archive)
                        dismiss()
                    }
                }

                Section("Account") {
                    MoreMenuItem(icon: "person.fill", title: "Profile") {
                        onSelect(.connections) // Triggers profile sheet via MainNavigationView
                        dismiss()
                    }

                    MoreMenuItem(icon: "questionmark.circle.fill", title: "Guides") {
                        // Handled by MainNavigationView
                        dismiss()
                    }
                }

                Section("Vault") {
                    MoreMenuItem(icon: "key.fill", title: "Credentials") {
                        dismiss()
                    }

                    MoreMenuItem(icon: "chart.bar.fill", title: "Vault Status") {
                        dismiss()
                    }

                    MoreMenuItem(icon: "externaldrive.fill", title: "Backups") {
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

        BottomNavBar(
            currentItem: .constant(.feed),
            badgeCounts: BadgeCountsViewModel(),
            onMoreTap: {}
        )
    }
}
