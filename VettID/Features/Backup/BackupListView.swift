import SwiftUI

/// Main backup list view
struct BackupListView: View {
    let authTokenProvider: @Sendable () -> String?

    @StateObject private var viewModel: BackupListViewModel
    @State private var showSettings = false
    @State private var showCreateBackup = false

    init(authTokenProvider: @escaping @Sendable () -> String?) {
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: BackupListViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        NavigationView {
            Group {
                switch viewModel.state {
                case .loading:
                    loadingView

                case .empty:
                    emptyView

                case .loaded(let backups):
                    backupsList(backups)

                case .error(let message):
                    errorView(message)
                }
            }
            .navigationTitle("Backups")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showCreateBackup = true }) {
                        Image(systemName: "plus")
                    }
                    .disabled(viewModel.isCreatingBackup)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            BackupSettingsView(authTokenProvider: authTokenProvider)
        }
        .sheet(isPresented: $showCreateBackup) {
            CreateBackupView(
                authTokenProvider: self.authTokenProvider,
                onComplete: { [viewModel] in
                    Task { @MainActor in
                        await viewModel.refresh()
                    }
                }
            )
        }
        .task {
            await viewModel.loadBackups()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
            Text("Loading backups...")
                .foregroundColor(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Backups Yet")
                .font(.headline)

            Text("Create your first backup to protect your data")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Create Backup") {
                showCreateBackup = true
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Backups List

    private func backupsList(_ backups: [Backup]) -> some View {
        List {
            ForEach(backups) { backup in
                NavigationLink(destination: BackupDetailView(
                    backupId: backup.id,
                    authTokenProvider: authTokenProvider
                )) {
                    BackupListRow(backup: backup)
                }
            }
            .onDelete { indexSet in
                viewModel.deleteBackups(at: indexSet)
            }
        }
        .refreshable {
            await viewModel.refresh()
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
                Task { await viewModel.loadBackups() }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
    }
}

// MARK: - Backup List Row

struct BackupListRow: View {
    let backup: Backup

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(backup.createdAt, style: .date)
                    .font(.headline)
                Text(backup.createdAt, style: .time)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                BackupTypeBadge(type: backup.type)
                Text(formatBytes(backup.sizeBytes))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Backup Type Badge

struct BackupTypeBadge: View {
    let type: BackupType

    var body: some View {
        Text(type == .auto ? "Auto" : "Manual")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(type == .auto ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
            .foregroundColor(type == .auto ? .blue : .green)
            .cornerRadius(4)
    }
}

// MARK: - Create Backup View

struct CreateBackupView: View {
    let authTokenProvider: @Sendable () -> String?
    let onComplete: @Sendable () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var includeMessages = true
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("Include Messages", isOn: $includeMessages)
                } footer: {
                    Text("Messages can make backups larger but ensure your conversation history is preserved.")
                }

                Section {
                    Button(action: createBackup) {
                        HStack {
                            Spacer()
                            if isCreating {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isCreating ? "Creating..." : "Create Backup")
                            Spacer()
                        }
                    }
                    .disabled(isCreating)
                }
            }
            .navigationTitle("New Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
            }
            .alert("Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                if let error = error {
                    Text(error)
                }
            }
        }
    }

    private func createBackup() {
        guard let authToken = authTokenProvider() else {
            error = "Not authenticated"
            return
        }

        isCreating = true

        Task {
            do {
                let apiClient = APIClient()
                _ = try await apiClient.triggerBackup(
                    includeMessages: includeMessages,
                    authToken: authToken
                )
                onComplete()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isCreating = false
            }
        }
    }
}

#if DEBUG
struct BackupListView_Previews: PreviewProvider {
    static var previews: some View {
        BackupListView(authTokenProvider: { "test-token" })
    }
}
#endif
