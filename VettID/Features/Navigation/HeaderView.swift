import SwiftUI

// MARK: - Header View

struct HeaderView: View {
    let title: String
    let onProfileTap: () -> Void
    var actionIcon: String? = nil
    var onActionTap: (() -> Void)? = nil
    var secondaryActionIcon: String? = nil
    var onSecondaryActionTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 16) {
            // Profile avatar (opens drawer)
            Button(action: onProfileTap) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
            }

            Spacer()

            // Title
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()

            // Action buttons
            HStack(spacing: 12) {
                if let secondaryIcon = secondaryActionIcon,
                   let secondaryAction = onSecondaryActionTap {
                    Button(action: secondaryAction) {
                        Image(systemName: secondaryIcon)
                            .font(.system(size: 18))
                    }
                }

                if let icon = actionIcon, let action = onActionTap {
                    Button(action: action) {
                        Image(systemName: icon)
                            .font(.system(size: 18))
                    }
                }
            }
            .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }
}

// MARK: - Searchable Header View

struct SearchableHeaderView: View {
    let title: String
    let onProfileTap: () -> Void
    @Binding var searchText: String
    @Binding var isSearching: Bool
    var actionIcon: String? = nil
    var onActionTap: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Profile avatar (opens drawer)
                Button(action: onProfileTap) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.blue)
                }

                if isSearching {
                    // Search field
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("Search", text: $searchText)
                            .textFieldStyle(.plain)

                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)

                    Button("Cancel") {
                        searchText = ""
                        isSearching = false
                    }
                    .foregroundStyle(.blue)
                } else {
                    Spacer()

                    Text(title)
                        .font(.headline)
                        .fontWeight(.semibold)

                    Spacer()

                    // Action buttons
                    HStack(spacing: 12) {
                        Button(action: { isSearching = true }) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 18))
                        }

                        if let icon = actionIcon, let action = onActionTap {
                            Button(action: action) {
                                Image(systemName: icon)
                                    .font(.system(size: 18))
                            }
                        }
                    }
                    .frame(width: 60, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
    }
}

// MARK: - Header Configuration

struct HeaderConfiguration {
    let title: String
    var actionIcon: String? = nil
    var onActionTap: (() -> Void)? = nil
    var secondaryActionIcon: String? = nil
    var onSecondaryActionTap: (() -> Void)? = nil
    var showSearch: Bool = false

    // Vault section headers
    static func connections(onAdd: @escaping () -> Void) -> HeaderConfiguration {
        HeaderConfiguration(
            title: "Connections",
            actionIcon: "plus",
            onActionTap: onAdd,
            showSearch: true
        )
    }

    static func feed() -> HeaderConfiguration {
        HeaderConfiguration(title: "Feed")
    }

    // Vault Services section headers
    static func services() -> HeaderConfiguration {
        HeaderConfiguration(title: "Vault Services")
    }

    static func handlers(onDiscover: @escaping () -> Void) -> HeaderConfiguration {
        HeaderConfiguration(
            title: "Handlers",
            actionIcon: "magnifyingglass",
            onActionTap: onDiscover
        )
    }

    static func backups(onAdd: @escaping () -> Void) -> HeaderConfiguration {
        HeaderConfiguration(
            title: "Backups",
            actionIcon: "plus",
            onActionTap: onAdd
        )
    }

    // App Settings section headers
    static func settings() -> HeaderConfiguration {
        HeaderConfiguration(title: "Settings")
    }

    static func profile(onEdit: @escaping () -> Void) -> HeaderConfiguration {
        HeaderConfiguration(
            title: "Profile",
            actionIcon: "pencil",
            onActionTap: onEdit
        )
    }

    static func secrets(onAdd: @escaping () -> Void) -> HeaderConfiguration {
        HeaderConfiguration(
            title: "Secrets",
            actionIcon: "plus",
            onActionTap: onAdd,
            showSearch: true
        )
    }

    static func personalData(onAdd: @escaping () -> Void) -> HeaderConfiguration {
        HeaderConfiguration(
            title: "Personal Data",
            actionIcon: "plus",
            onActionTap: onAdd
        )
    }
}

// MARK: - Preview

#Preview {
    VStack {
        HeaderView(
            title: "Connections",
            onProfileTap: {},
            actionIcon: "plus",
            onActionTap: {}
        )

        Divider()

        HeaderView(
            title: "Feed",
            onProfileTap: {}
        )

        Divider()

        SearchableHeaderView(
            title: "Secrets",
            onProfileTap: {},
            searchText: .constant(""),
            isSearching: .constant(false),
            actionIcon: "plus",
            onActionTap: {}
        )

        Spacer()
    }
}
