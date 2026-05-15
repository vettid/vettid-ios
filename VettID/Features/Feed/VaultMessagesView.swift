import SwiftUI

// MARK: - Vault Messages View

/// Surfaces deferred vault updates — messages from the user's own vault
/// that weren't actioned immediately (paused migrations, queued PCR
/// updates, deferred consent decisions, …).
///
/// Reached by tapping the body of the VettID system connection card in
/// the feed. Parity with Android `VaultMessagesScreen`.
///
/// **Phase 1.2 scope**: the screen scaffold lands here; the underlying
/// queue (`vault.messages.list` and friends) will be wired up once it
/// exists on iOS's vault. For now this renders an empty state.
struct VaultMessagesView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "tray.full")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                    .padding(.top, 48)

                Text("No vault messages")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("Deferred vault updates and queued decisions show up here. When your vault has something for you, it'll appear in this list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Vault messages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
