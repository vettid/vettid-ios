import SwiftUI

struct ManageVaultView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ManageVaultViewModel()

    @State private var showStopConfirmation = false
    @State private var showRestartConfirmation = false
    @State private var showTerminateConfirmation = false
    @State private var terminateConfirmText = ""

    var body: some View {
        List {
            if !appState.hasActiveVault {
                noVaultSection
            } else {
                vaultActionsSection
                vaultInfoSection
                dangerZoneSection
            }
        }
        .navigationTitle("Manage")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Stop Vault", isPresented: $showStopConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Stop", role: .destructive) {
                Task { await viewModel.stopVault() }
            }
        } message: {
            Text("Your vault will be stopped. You can restart it at any time. Active connections will be interrupted.")
        }
        .alert("Restart Vault", isPresented: $showRestartConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Restart") {
                Task { await viewModel.restartVault() }
            }
        } message: {
            Text("Your vault will be restarted. Active connections will be briefly interrupted.")
        }
        .sheet(isPresented: $showTerminateConfirmation) {
            TerminateVaultSheet(
                confirmText: $terminateConfirmText,
                instanceId: appState.vaultInstanceId ?? "",
                onConfirm: {
                    Task { await viewModel.terminateVault() }
                }
            )
        }
    }

    // MARK: - No Vault Section

    private var noVaultSection: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "cloud")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)

                Text("No Vault Deployed")
                    .font(.headline)

                Text("Deploy a vault from the Status tab to manage it here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    // MARK: - Vault Actions Section

    private var vaultActionsSection: some View {
        Section {
            // Stop Vault
            Button {
                showStopConfirmation = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stop Vault")
                            .foregroundStyle(.primary)

                        Text("Pause your vault instance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.orange)
                }
            }
            .disabled(viewModel.isLoading)

            // Restart Vault
            Button {
                showRestartConfirmation = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Restart Vault")
                            .foregroundStyle(.primary)

                        Text("Restart your vault instance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.blue)
                }
            }
            .disabled(viewModel.isLoading)
        } header: {
            Text("Vault Actions")
        } footer: {
            Text("Stopping your vault will disconnect active sessions. Data remains safe and encrypted.")
        }
    }

    // MARK: - Vault Info Section

    private var vaultInfoSection: some View {
        Section("Vault Information") {
            if let instanceId = appState.vaultInstanceId {
                HStack {
                    Text("Instance ID")
                    Spacer()
                    Text(instanceId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Status")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.statusColor)
                        .frame(width: 8, height: 8)
                    Text(viewModel.statusText)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Region")
                Spacer()
                Text(viewModel.region)
                    .foregroundStyle(.secondary)
            }

            if let createdAt = viewModel.createdAt {
                HStack {
                    Text("Created")
                    Spacer()
                    Text(createdAt, style: .date)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Danger Zone Section

    private var dangerZoneSection: some View {
        Section {
            Button(role: .destructive) {
                showTerminateConfirmation = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Terminate Vault")

                        Text("Permanently delete your vault instance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "trash.fill")
                }
            }
            .disabled(viewModel.isLoading)
        } header: {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Danger Zone")
            }
        } footer: {
            Text("Terminating your vault is permanent and cannot be undone. All vault data will be permanently deleted. Make sure you have a backup before proceeding.")
        }
    }
}

// MARK: - Terminate Vault Sheet

struct TerminateVaultSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var confirmText: String
    let instanceId: String
    let onConfirm: () -> Void

    @State private var isLoading = false

    private var confirmationPhrase: String {
        "DELETE \(String(instanceId.prefix(8)))"
    }

    private var isConfirmed: Bool {
        confirmText.uppercased() == confirmationPhrase
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Warning icon
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.red)
                    .padding(.top, 32)

                // Warning text
                VStack(spacing: 12) {
                    Text("Terminate Vault?")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("This action is permanent and cannot be undone. All data in your vault will be permanently deleted.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // What will be deleted
                VStack(alignment: .leading, spacing: 12) {
                    Text("This will permanently delete:")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 8) {
                        DeletedItemRow(icon: "key.fill", text: "All encryption keys")
                        DeletedItemRow(icon: "message.fill", text: "All messages")
                        DeletedItemRow(icon: "person.2.fill", text: "All connection data")
                        DeletedItemRow(icon: "doc.fill", text: "All stored credentials")
                    }
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal)

                // Confirmation input
                VStack(alignment: .leading, spacing: 8) {
                    Text("To confirm, type: **\(confirmationPhrase)**")
                        .font(.subheadline)

                    TextField("Type confirmation", text: $confirmText)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.allCharacters)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal)

                Spacer()

                // Buttons
                VStack(spacing: 12) {
                    Button(role: .destructive) {
                        isLoading = true
                        onConfirm()
                        dismiss()
                    } label: {
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Terminate Vault")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!isConfirmed || isLoading)

                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct DeletedItemRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.red)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - View Model

@MainActor
class ManageVaultViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var statusText = "Running"
    @Published var statusColor = Color.green
    @Published var region = "us-east-1"
    @Published var createdAt: Date? = Date().addingTimeInterval(-86400 * 30) // 30 days ago

    func stopVault() async {
        isLoading = true
        defer { isLoading = false }

        // TODO: Implement actual vault stop via API
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        statusText = "Stopped"
        statusColor = .orange
    }

    func restartVault() async {
        isLoading = true
        defer { isLoading = false }

        // TODO: Implement actual vault restart via API
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        statusText = "Running"
        statusColor = .green
    }

    func terminateVault() async {
        isLoading = true
        defer { isLoading = false }

        // TODO: Implement actual vault termination via API
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }
}

// MARK: - Preview

#Preview("With Vault") {
    NavigationStack {
        ManageVaultView()
    }
    .environmentObject({
        let state = AppState()
        state.hasActiveVault = true
        state.vaultInstanceId = "vault-abc123def456"
        return state
    }())
}

#Preview("No Vault") {
    NavigationStack {
        ManageVaultView()
    }
    .environmentObject(AppState())
}
