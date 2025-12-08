import SwiftUI

/// Backup detail and restore view
struct BackupDetailView: View {
    let backupId: String
    let authTokenProvider: @Sendable () -> String?

    @StateObject private var viewModel: BackupDetailViewModel
    @State private var showRestoreConfirmation = false
    @State private var showDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss

    init(backupId: String, authTokenProvider: @escaping @Sendable () -> String?) {
        self.backupId = backupId
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: BackupDetailViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                loadingView
            } else if let backup = viewModel.backup {
                contentView(backup)
            } else if let error = viewModel.errorMessage {
                errorView(error)
            }
        }
        .navigationTitle("Backup Details")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Restore Backup",
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore") {
                Task { await viewModel.restoreBackup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will replace your current data with the backup. This action cannot be undone.")
        }
        .confirmationDialog(
            "Delete Backup",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if await viewModel.deleteBackup() {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this backup? This action cannot be undone.")
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil && !viewModel.isLoading)) {
            Button("OK") { viewModel.clearError() }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .sheet(isPresented: .constant(viewModel.restoreResult != nil)) {
            if let result = viewModel.restoreResult {
                RestoreResultView(result: result) {
                    viewModel.clearRestoreResult()
                }
            }
        }
        .task {
            await viewModel.loadBackup(backupId)
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
            Text("Loading backup details...")
                .foregroundColor(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Content View

    private func contentView(_ backup: Backup) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // Backup info card
                BackupInfoCard(backup: backup)

                // Contents preview
                if let contents = viewModel.backupContents {
                    BackupContentsCard(contents: contents)
                }

                // Actions
                VStack(spacing: 12) {
                    Button(action: { showRestoreConfirmation = true }) {
                        HStack {
                            if viewModel.isRestoring {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Label(
                                viewModel.isRestoring ? "Restoring..." : "Restore from Backup",
                                systemImage: "arrow.counterclockwise"
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isRestoring || viewModel.isDeleting)

                    Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                        HStack {
                            if viewModel.isDeleting {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Label(
                                viewModel.isDeleting ? "Deleting..." : "Delete Backup",
                                systemImage: "trash"
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isRestoring || viewModel.isDeleting)
                }
                .padding(.horizontal)
            }
            .padding()
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.red)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                Task { await viewModel.loadBackup(backupId) }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
    }
}

// MARK: - Backup Info Card

struct BackupInfoCard: View {
    let backup: Backup

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "externaldrive.fill")
                    .font(.title2)
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(backup.createdAt, style: .date)
                        .font(.headline)
                    Text(backup.createdAt, style: .time)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                BackupTypeBadge(type: backup.type)
            }

            Divider()

            VStack(spacing: 12) {
                InfoRow(label: "Status", value: backup.status.rawValue.capitalized)
                InfoRow(label: "Size", value: formatBytes(backup.sizeBytes))
                InfoRow(label: "Encryption", value: backup.encryptionMethod)
                InfoRow(label: "ID", value: String(backup.id.prefix(12)) + "...")
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Info Row

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Backup Contents Card

struct BackupContentsCard: View {
    let contents: BackupContents

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Contents")
                .font(.headline)

            Divider()

            VStack(spacing: 12) {
                ContentsRow(icon: "key.fill", label: "Credentials", count: contents.credentialsCount)
                ContentsRow(icon: "person.2.fill", label: "Connections", count: contents.connectionsCount)
                ContentsRow(icon: "message.fill", label: "Messages", count: contents.messagesCount)
                ContentsRow(icon: "puzzlepiece.fill", label: "Handlers", count: contents.handlersCount)

                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(.secondary)
                        .frame(width: 24)
                    Text("Profile")
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: contents.profileIncluded ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(contents.profileIncluded ? .green : .secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Contents Row

struct ContentsRow: View {
    let icon: String
    let label: String
    let count: Int

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 24)
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text("\(count)")
                .fontWeight(.medium)
        }
    }
}

// MARK: - Restore Result View

struct RestoreResultView: View {
    let result: RestoreResult
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(result.success ? .green : .orange)

                Text(result.success ? "Restore Complete" : "Restore Completed with Issues")
                    .font(.title2)
                    .fontWeight(.semibold)

                VStack(spacing: 8) {
                    Text("\(result.restoredItems) items restored")
                        .foregroundColor(.secondary)

                    if !result.conflicts.isEmpty {
                        Text("\(result.conflicts.count) conflicts detected")
                            .foregroundColor(.orange)
                    }

                    if result.requiresReauth {
                        Text("Re-authentication required")
                            .foregroundColor(.blue)
                    }
                }

                if !result.conflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Conflicts:")
                            .font(.headline)

                        ForEach(result.conflicts, id: \.self) { conflict in
                            Text("• \(conflict)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }

                Spacer()

                Button("Done") {
                    onDismiss()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Restore Result")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#if DEBUG
struct BackupDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            BackupDetailView(
                backupId: "test-backup-id",
                authTokenProvider: { "test-token" }
            )
        }
    }
}
#endif
