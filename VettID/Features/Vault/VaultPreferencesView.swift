import SwiftUI

/// Vault preferences and settings view
struct VaultPreferencesView: View {
    @EnvironmentObject var appState: AppState
    @State private var sessionTTL: SessionTTL = .fifteenMinutes
    @State private var archiveAfterDays: Int = 30
    @State private var deleteAfterDays: Int = 90
    @State private var showChangePassword = false
    @State private var isSaving = false

    var body: some View {
        List {
            // Session Settings
            Section {
                Picker("Session Timeout", selection: $sessionTTL) {
                    ForEach(SessionTTL.allCases, id: \.rawValue) { ttl in
                        Text(ttl.displayName).tag(ttl)
                    }
                }
            } header: {
                Text("Session")
            } footer: {
                Text("How long vault sessions remain active before requiring re-authentication.")
            }

            // Security
            Section {
                Button(action: { showChangePassword = true }) {
                    HStack {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        Text("Change Vault Password")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Security")
            } footer: {
                Text("Your vault password is separate from your Vault Services password.")
            }

            // Handlers
            Section {
                NavigationLink(destination: HandlerDiscoveryView(viewModel: HandlerDiscoveryViewModel(authTokenProvider: { nil }))) {
                    HStack {
                        Image(systemName: "gearshape.2.fill")
                            .foregroundStyle(.purple)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Manage Handlers")
                            Text("Configure event handlers")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Automation")
            }

            // Archive Settings
            Section {
                Stepper(value: $archiveAfterDays, in: 7...365, step: 7) {
                    HStack {
                        Text("Archive after")
                        Spacer()
                        Text("\(archiveAfterDays) days")
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper(value: $deleteAfterDays, in: 30...730, step: 30) {
                    HStack {
                        Text("Delete after")
                        Spacer()
                        Text("\(deleteAfterDays) days")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Archive")
            } footer: {
                Text("Items older than the archive threshold are moved to archive. Archived items are permanently deleted after the delete threshold.")
            }

            // Data Management
            Section {
                NavigationLink(destination: ArchiveView()) {
                    HStack {
                        Image(systemName: "archivebox.fill")
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("View Archive")
                            Text("Browse archived items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button(role: .destructive, action: clearCache) {
                    HStack {
                        Image(systemName: "trash.fill")
                            .frame(width: 24)
                        Text("Clear Local Cache")
                    }
                }
            } header: {
                Text("Data")
            }
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showChangePassword) {
            ChangeVaultPasswordSheet()
        }
    }

    private func clearCache() {
        // TODO: Implement cache clearing
    }
}

// MARK: - Session TTL

enum SessionTTL: Int, CaseIterable {
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60
    case fourHours = 240

    var displayName: String {
        switch self {
        case .fiveMinutes:
            return "5 minutes"
        case .fifteenMinutes:
            return "15 minutes"
        case .thirtyMinutes:
            return "30 minutes"
        case .oneHour:
            return "1 hour"
        case .fourHours:
            return "4 hours"
        }
    }
}

// MARK: - Change Vault Password Sheet

struct ChangeVaultPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    SecureField("Current Password", text: $currentPassword)
                } header: {
                    Text("Current Password")
                }

                Section {
                    SecureField("New Password", text: $newPassword)
                    SecureField("Confirm New Password", text: $confirmPassword)
                } header: {
                    Text("New Password")
                } footer: {
                    Text("Password must be at least 8 characters.")
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: changePassword) {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isLoading ? "Changing..." : "Change Password")
                            Spacer()
                        }
                    }
                    .disabled(!isValid || isLoading)
                }
            }
            .navigationTitle("Change Vault Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var isValid: Bool {
        !currentPassword.isEmpty &&
        newPassword.count >= 8 &&
        newPassword == confirmPassword
    }

    private func changePassword() {
        guard isValid else { return }

        isLoading = true
        errorMessage = nil

        // TODO: Implement via NATS to vault
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                isLoading = false
                dismiss()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        VaultPreferencesView()
    }
    .environmentObject(AppState())
}
