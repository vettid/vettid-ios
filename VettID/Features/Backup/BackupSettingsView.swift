import SwiftUI

/// Backup settings view
struct BackupSettingsView: View {
    let authTokenProvider: @Sendable () -> String?

    @StateObject private var viewModel: BackupSettingsViewModel
    @Environment(\.dismiss) private var dismiss

    init(authTokenProvider: @escaping @Sendable () -> String?) {
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: BackupSettingsViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoading {
                    ProgressView("Loading settings...")
                } else {
                    settingsForm
                }
            }
            .navigationTitle("Backup Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task {
                            await viewModel.saveSettings()
                            dismiss()
                        }
                    }
                    .disabled(viewModel.isSaving)
                }
            }
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.clearError() }
            } message: {
                if let error = viewModel.errorMessage {
                    Text(error)
                }
            }
        }
        .task {
            await viewModel.loadSettings()
        }
    }

    // MARK: - Settings Form

    private var settingsForm: some View {
        Form {
            // Automatic backup section
            Section("Automatic Backup") {
                Toggle("Enable Auto-Backup", isOn: $viewModel.settings.autoBackupEnabled)

                if viewModel.settings.autoBackupEnabled {
                    Picker("Frequency", selection: $viewModel.settings.backupFrequency) {
                        ForEach(BackupFrequency.allCases, id: \.self) { frequency in
                            Text(frequency.displayName)
                        }
                    }

                    DatePicker(
                        "Time",
                        selection: $viewModel.backupTime,
                        displayedComponents: .hourAndMinute
                    )

                    Toggle("WiFi Only", isOn: $viewModel.settings.wifiOnly)
                }
            }

            // Content section
            Section("Content") {
                Toggle("Include Messages", isOn: $viewModel.settings.includeMessages)

                Stepper(
                    "Keep \(viewModel.settings.retentionDays) days",
                    value: $viewModel.settings.retentionDays,
                    in: 7...365,
                    step: 7
                )
            }

            // Status section
            Section {
                if let lastBackup = viewModel.lastBackupDate {
                    HStack {
                        Text("Last Backup")
                        Spacer()
                        Text(lastBackup, style: .relative)
                            .foregroundColor(.secondary)
                    }
                }

                Button(action: {
                    Task { await viewModel.backupNow() }
                }) {
                    HStack {
                        if viewModel.isBackingUp {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Text(viewModel.isBackingUp ? "Backing up..." : "Backup Now")
                    }
                }
                .disabled(viewModel.isBackingUp)
            }

            // Credential recovery section
            Section {
                NavigationLink(destination: ProteanRecoveryView(authTokenProvider: authTokenProvider)) {
                    HStack {
                        Text("Credential Recovery")
                        Spacer()
                        if viewModel.credentialBackupExists {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Text("Not Backed Up")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("Credential Protection")
            } footer: {
                Text("Your credential is encrypted and stored securely. Recovery requires a 24-hour waiting period for security.")
            }

            // Backup list link
            Section {
                NavigationLink(destination: BackupListView(authTokenProvider: authTokenProvider)) {
                    HStack {
                        Image(systemName: "externaldrive")
                            .foregroundColor(.blue)
                        Text("View All Backups")
                    }
                }
            }
        }
    }
}

#if DEBUG
struct BackupSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        BackupSettingsView(authTokenProvider: { "test-token" })
    }
}
#endif
