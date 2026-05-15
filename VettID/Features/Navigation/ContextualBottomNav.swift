import SwiftUI

// MARK: - Bottom Nav Item

/// Top-level destination tabs. Phase 1.3 (Android parity, commit 904452f
/// "nav: rename Activity → Connections, remove Feed/Voting/Archive tabs")
/// collapses the bottom nav to just two destinations: ACTIVITY (the
/// connection-centric feed, titled "Connections") + VAULT
/// (Data/Secrets/Wallets segmented). Voting / Guides / Archive are no
/// longer tabs — they're reached through the VettID system card and the
/// archived-connections footer respectively.
///
/// `.more` stays as a third button for everything else (Personal Data
/// detail surfaces, Devices, Audit Log, …). It opens `MoreMenuSheet`.
enum BottomNavItem: Int, CaseIterable {
    case activity = 0
    case vault = 1
    case more = 2

    var title: String {
        switch self {
        case .activity: return "Connections"
        case .vault:    return "Vault"
        case .more:     return "More"
        }
    }

    var icon: String {
        switch self {
        case .activity: return "person.2.fill"
        case .vault:    return "lock.shield.fill"
        case .more:     return "ellipsis"
        }
    }

    /// Corresponding DrawerItem (nil for "More"). ACTIVITY maps to
    /// `connections` — the connection-centric feed is THE connections
    /// list now. VAULT maps to a synthetic `vault` item that
    /// MainNavigationView resolves to the segmented Vault scaffold.
    var drawerItem: DrawerItem? {
        switch self {
        case .activity: return .connections
        case .vault:    return .vault
        case .more:     return nil
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
        case .activity:
            // Activity badge folds together the things that used to be
            // separate tabs: unread feed, pending connections, and
            // unvoted proposals (which now surface on the VettID
            // system card inside the feed).
            return badgeCounts.unreadFeedCount
                 + badgeCounts.pendingConnectionsCount
                 + badgeCounts.unvotedProposalsCount
        case .vault, .more:
            return 0
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
            .accessibilityLabel("\(count) unread")
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

                    // Phase 3.4: Grants inbox — pending requests +
                    // outbound/inbound grants. Reachable here for users
                    // who want to triage from one screen rather than
                    // tapping pending rows on individual connection
                    // cards.
                    MoreMenuItem(icon: DrawerItem.grants.icon, title: DrawerItem.grants.title) {
                        onSelect(.grants)
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
                    MoreMenuItem(icon: DrawerItem.devices.icon, title: DrawerItem.devices.title) {
                        onSelect(.devices)
                        dismiss()
                    }

                    MoreMenuItem(icon: DrawerItem.auditLog.icon, title: DrawerItem.auditLog.title) {
                        onSelect(.auditLog)
                        dismiss()
                    }

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
            currentItem: .constant(.connections),
            badgeCounts: BadgeCountsViewModel(),
            onMoreTap: {}
        )
    }
}
