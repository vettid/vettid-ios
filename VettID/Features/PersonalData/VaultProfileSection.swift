import SwiftUI

// MARK: - Vault Profile Section

/// Persistent profile strip that sits above the Vault destination's
/// segmented control (Data / Secrets / Wallets). Shows the user's own
/// avatar + display name + a one-tap "Available Personal Data" affordance
/// so the catalog is always one button away regardless of which segment
/// is active.
///
/// Phase 2.10 — parity with Android `VaultProfileSection`. Reads directly
/// from `PersonalDataStore` so it stays current as fields edit / photo
/// changes land via the snapshot tick. The user's "own card" comes from
/// `AppState.currentProfile`, which is itself synthesized from
/// `PersonalDataStore` after Phase 2.2.
struct VaultProfileSection: View {

    @EnvironmentObject private var appState: AppState
    /// Binding from the parent so tapping the strip hops to the Data
    /// segment before the dialog appears. Optional — when nil, the
    /// segment isn't switched.
    var segment: Binding<VaultSegment>?
    @State private var showAvailableData = false

    var body: some View {
        // Matches Android `VaultProfileSection`: avatar + clickable
        // name/subtitle column, no trailing icon button. Tapping the
        // name column flips to the Data segment and opens the
        // catalog preview.
        Button {
            segment?.wrappedValue = .data
            showAvailableData = true
        } label: {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text("Tap to preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .accessibilityLabel("Tap to preview your profile")
        .sheet(isPresented: $showAvailableData) {
            AvailableDataCatalogView()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var avatar: some View {
        if let data = appState.currentProfile?.photoData,
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay(
                    Text(String(displayName.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                )
        }
    }

    private var displayName: String {
        appState.currentProfile?.displayName ?? "VettID User"
    }

}
