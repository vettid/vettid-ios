import SwiftUI

/// Main backup list view with sectioned layout
struct BackupListView: View {
    let authTokenProvider: @Sendable () -> String?

    @StateObject private var viewModel: BackupListViewModel
    @State private var showSettings = false
    @State private var showCreateBackup = false
    @State private var showCredentialRecovery = false

    init(authTokenProvider: @escaping @Sendable () -> String?) {
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: BackupListViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        List {
            // Credential Recovery Section
            Section {
                credentialRecoveryRow
            } header: {
                Text("Credential Protection")
            } footer: {
                Text("Your credentials are automatically backed up. Recovery requires a 24-hour security delay.")
            }

            // Auto-Backup Section
            Section {
                NavigationLink(destination: BackupSettingsView(authTokenProvider: authTokenProvider)) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Backup Settings")
                            Text("Configure automatic vault backups")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Automatic Backups")
            }

            // Vault Backups Section
            Section {
                switch viewModel.state {
                case .loading:
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)

                case .empty:
                    emptyBackupsRow

                case .loaded(let backups):
                    ForEach(backups.prefix(5)) { backup in
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

                    if backups.count > 5 {
                        NavigationLink(destination: AllBackupsView(authTokenProvider: authTokenProvider)) {
                            Text("View All \(backups.count) Backups")
                                .foregroundStyle(.blue)
                        }
                    }

                case .error(let message):
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack {
                    Text("Vault Backups")
                    Spacer()
                    Button(action: { showCreateBackup = true }) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                    }
                    .disabled(viewModel.isCreatingBackup)
                }
            } footer: {
                Text("Vault backups include your connections, messages, and vault data.")
            }
        }
        .navigationTitle("Backups")
        .refreshable {
            await viewModel.refresh()
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
        .sheet(isPresented: $showCredentialRecovery) {
            ProteanRecoveryView(authTokenProvider: authTokenProvider)
        }
        .task {
            await viewModel.loadBackups()
        }
    }

    // MARK: - Credential Recovery Row

    private var credentialRecoveryRow: some View {
        Button(action: { showCredentialRecovery = true }) {
            HStack {
                Image(systemName: "key.horizontal.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Credential Recovery")
                    Text("Request recovery with 24-hour security delay")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Empty Backups Row

    private var emptyBackupsRow: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Vault Backups")
                .font(.subheadline)
                .fontWeight(.medium)
            Text("Create your first backup to protect your vault data")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create Backup") {
                showCreateBackup = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .listRowBackground(Color.clear)
    }

}

// MARK: - All Backups View

/// Shows all vault backups in a full list
struct AllBackupsView: View {
    let authTokenProvider: @Sendable () -> String?

    @StateObject private var viewModel: BackupListViewModel
    @State private var showCreateBackup = false

    init(authTokenProvider: @escaping @Sendable () -> String?) {
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: BackupListViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView("Loading backups...")

            case .empty:
                VStack(spacing: 16) {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                    Text("No Backups")
                        .font(.headline)
                }

            case .loaded(let backups):
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

            case .error(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundStyle(.red)
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await viewModel.loadBackups() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("All Backups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showCreateBackup = true }) {
                    Image(systemName: "plus")
                }
            }
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
