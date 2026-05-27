import SwiftUI

// MARK: - NATS Connection Status Indicator
//
// Compact pill that mirrors Android's `NatsConnectionStatusIndicator`
// (used in `HeaderView.kt`). Renders a colored dot keyed off the
// current `NatsConnectionState` so the user can see at a glance
// whether the vault link is live. Tapping it opens Settings, same
// as the Android pattern (`onNatsStatusClick = onSettingsToggle`
// in MainScaffold).
struct NatsHeaderStatusIndicator: View {
    @EnvironmentObject var appState: AppState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle().stroke(Color.black.opacity(0.1), lineWidth: 0.5)
                )
                .accessibilityLabel("Vault connection: \(accessibilityText)")
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        switch appState.natsConnectionManager.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting, .startingVault, .waitingForVault:
            return .yellow
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private var accessibilityText: String {
        switch appState.natsConnectionManager.connectionState {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .reconnecting: return "reconnecting"
        case .startingVault: return "starting vault"
        case .waitingForVault: return "waiting for vault"
        case .disconnected: return "disconnected"
        case .error: return "error"
        }
    }
}

// MARK: - Header View

struct HeaderView: View {
    let title: String
    let onProfileTap: () -> Void
    var actionIcon: String? = nil
    var onActionTap: (() -> Void)? = nil
    var onSettingsTap: (() -> Void)? = nil
    var profilePhotoData: Data? = nil

    var body: some View {
        HStack(spacing: 16) {
            // Profile avatar — tap toggles Connections ↔ Vault.
            Button(action: onProfileTap) {
                if let photoData = profilePhotoData,
                   let uiImage = UIImage(data: photoData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.blue)
                }
            }

            Spacer()

            // Title
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()

            // Action buttons (Android order: action → NATS status → settings)
            HStack(spacing: 12) {
                if let icon = actionIcon, let action = onActionTap {
                    Button(action: action) {
                        Image(systemName: icon)
                            .font(.system(size: 18))
                    }
                }

                if let settingsAction = onSettingsTap {
                    NatsHeaderStatusIndicator(onTap: settingsAction)

                    Button(action: settingsAction) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18))
                    }
                }
            }
            .frame(minWidth: 32, alignment: .trailing)
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
    var onSettingsTap: (() -> Void)? = nil
    var profilePhotoData: Data? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Profile avatar (opens drawer)
                Button(action: onProfileTap) {
                    if let photoData = profilePhotoData,
                       let uiImage = UIImage(data: photoData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.blue)
                    }
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

                    // Action buttons (search → action → NATS status → settings).
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

                        if let settingsAction = onSettingsTap {
                            NatsHeaderStatusIndicator(onTap: settingsAction)

                            Button(action: settingsAction) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 18))
                            }
                        }
                    }
                    .frame(minWidth: 32, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        HeaderView(
            title: "Connections",
            onProfileTap: {},
            actionIcon: "plus",
            onActionTap: {},
            onSettingsTap: {}
        )

        Divider()

        HeaderView(
            title: "Feed",
            onProfileTap: {},
            onSettingsTap: {}
        )

        Divider()

        SearchableHeaderView(
            title: "Secrets",
            onProfileTap: {},
            searchText: .constant(""),
            isSearching: .constant(false),
            actionIcon: "plus",
            onActionTap: {},
            onSettingsTap: {}
        )

        Spacer()
    }
}
