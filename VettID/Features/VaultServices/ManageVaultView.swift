import SwiftUI

struct ManageVaultView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: ManageVaultViewModel

    @State private var showStartConfirmation = false
    @State private var showStopConfirmation = false
    @State private var showRestartConfirmation = false
    @State private var showTerminateConfirmation = false
    @State private var terminateConfirmText = ""

    init() {
        // Initialize with providers that will be populated from environment
        _viewModel = StateObject(wrappedValue: ManageVaultViewModel())
    }

    var body: some View {
        List {
            // Always show status section
            vaultStatusSection

            if appState.hasActiveVault {
                vaultActionsSection
                vaultInfoSection
                dangerZoneSection
            } else if viewModel.vaultStatus == .stopped {
                // Vault exists but is stopped - show start option
                stoppedVaultSection
            } else {
                noVaultSection
            }
        }
        .navigationTitle("Manage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Configure viewModel with appState providers
            viewModel.configure(
                authTokenProvider: { nil }, // TODO: Get from auth context
                userGuidProvider: { appState.currentUserGuid }
            )
            Task { await viewModel.refreshStatus() }
        }
        .refreshable {
            await viewModel.refreshStatus()
        }
        .alert("Start Vault", isPresented: $showStartConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Start") {
                Task { await viewModel.startVault() }
            }
        } message: {
            Text("Your vault will be started. This may take a moment.")
        }
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
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Vault Status Section

    private var vaultStatusSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vault Server")
                        .font(.headline)
                    Text(viewModel.vaultStatus.displayName)
                        .font(.subheadline)
                        .foregroundStyle(viewModel.vaultStatus.color)
                }

                Spacer()

                if viewModel.isLoading {
                    ProgressView()
                } else {
                    Circle()
                        .fill(viewModel.vaultStatus.color)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            if let instanceId = appState.vaultInstanceId {
                Text("Instance: \(String(instanceId.prefix(12)))...")
            }
        }
    }

    // MARK: - Stopped Vault Section

    private var stoppedVaultSection: some View {
        Section {
            Button {
                showStartConfirmation = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start Vault")
                            .foregroundStyle(.primary)

                        Text("Resume your vault instance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.green)
                }
            }
            .disabled(viewModel.isLoading)
        } header: {
            Text("Vault Actions")
        } footer: {
            Text("Your vault is currently stopped. Start it to resume operations.")
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
                        .fill(viewModel.vaultStatus.color)
                        .frame(width: 8, height: 8)
                    Text(viewModel.vaultStatus.displayName)
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

// MARK: - Vault Server Status

enum VaultServerStatus: Equatable {
    case unknown
    case loading
    case running
    case stopped
    case starting
    case stopping
    case pending
    case error(String)

    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .loading: return "Checking..."
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .starting: return "Starting..."
        case .stopping: return "Stopping..."
        case .pending: return "Pending"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var color: Color {
        switch self {
        case .running: return .green
        case .stopped: return .orange
        case .starting, .stopping, .pending, .loading: return .blue
        case .error: return .red
        case .unknown: return .gray
        }
    }

    static func == (lhs: VaultServerStatus, rhs: VaultServerStatus) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown), (.loading, .loading), (.running, .running),
             (.stopped, .stopped), (.starting, .starting), (.stopping, .stopping),
             (.pending, .pending):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - View Model

@MainActor
class ManageVaultViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var vaultStatus: VaultServerStatus = .unknown
    @Published var region = "us-east-1"
    @Published var createdAt: Date?
    @Published var errorMessage: String?

    private let apiClient = APIClient()
    private var authTokenProvider: () -> String? = { nil }
    private var userGuidProvider: () -> String? = { nil }

    /// Configure the view model with auth and user providers
    func configure(
        authTokenProvider: @escaping () -> String?,
        userGuidProvider: @escaping () -> String?
    ) {
        self.authTokenProvider = authTokenProvider
        self.userGuidProvider = userGuidProvider
    }

    /// Refresh vault status using action-token flow
    func refreshStatus() async {
        guard let userGuid = userGuidProvider(),
              let authToken = authTokenProvider() else {
            // No auth - can't check status
            return
        }

        vaultStatus = .loading

        do {
            let status = try await apiClient.getVaultStatusAction(
                userGuid: userGuid,
                cognitoToken: authToken
            )
            updateStatus(from: status.instanceStatus)
        } catch {
            // Fall back to health check if action-token fails
            await refreshStatusViaHealth()
        }
    }

    /// Fall back to health endpoint for status
    private func refreshStatusViaHealth() async {
        guard let authToken = authTokenProvider() else { return }

        do {
            let health = try await apiClient.getVaultHealth(authToken: authToken)
            switch health.status {
            case "healthy", "degraded":
                vaultStatus = .running
            default:
                vaultStatus = .unknown
            }
        } catch {
            vaultStatus = .unknown
        }
    }

    private func updateStatus(from instanceStatus: String?) {
        switch instanceStatus {
        case "running":
            vaultStatus = .running
        case "stopped":
            vaultStatus = .stopped
        case "starting", "pending":
            vaultStatus = .starting
        case "stopping":
            vaultStatus = .stopping
        case "terminated":
            vaultStatus = .stopped
        default:
            vaultStatus = .unknown
        }
    }

    /// Start the vault using action-token flow
    func startVault() async {
        guard let userGuid = userGuidProvider(),
              let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isLoading = true
        vaultStatus = .starting

        do {
            let response = try await apiClient.startVaultAction(
                userGuid: userGuid,
                cognitoToken: authToken
            )

            if response.status == "running" {
                vaultStatus = .running
            } else if response.status == "starting" || response.status == "pending" {
                // Poll for completion
                await pollForRunning(userGuid: userGuid, authToken: authToken)
            } else {
                vaultStatus = .error(response.message)
            }
        } catch {
            errorMessage = "Failed to start vault: \(error.localizedDescription)"
            vaultStatus = .stopped
        }

        isLoading = false
    }

    /// Stop the vault using action-token flow
    func stopVault() async {
        guard let userGuid = userGuidProvider(),
              let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isLoading = true
        vaultStatus = .stopping

        do {
            let response = try await apiClient.stopVaultAction(
                userGuid: userGuid,
                cognitoToken: authToken
            )

            if response.status == "stopped" || response.status == "stopping" {
                vaultStatus = .stopped
            } else {
                vaultStatus = .error(response.message)
            }
        } catch {
            errorMessage = "Failed to stop vault: \(error.localizedDescription)"
            await refreshStatus()
        }

        isLoading = false
    }

    /// Restart the vault (stop + start)
    func restartVault() async {
        guard let userGuid = userGuidProvider(),
              let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isLoading = true
        vaultStatus = .stopping

        do {
            // Stop first
            _ = try await apiClient.stopVaultAction(
                userGuid: userGuid,
                cognitoToken: authToken
            )

            // Brief delay
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Start again
            vaultStatus = .starting
            let response = try await apiClient.startVaultAction(
                userGuid: userGuid,
                cognitoToken: authToken
            )

            if response.status == "running" {
                vaultStatus = .running
            } else if response.status == "starting" || response.status == "pending" {
                await pollForRunning(userGuid: userGuid, authToken: authToken)
            } else {
                vaultStatus = .error(response.message)
            }
        } catch {
            errorMessage = "Failed to restart vault: \(error.localizedDescription)"
            await refreshStatus()
        }

        isLoading = false
    }

    /// Terminate the vault
    func terminateVault() async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isLoading = true

        do {
            _ = try await apiClient.terminateVault(authToken: authToken)
            vaultStatus = .stopped
        } catch {
            errorMessage = "Failed to terminate vault: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// Poll until vault is running or timeout
    private func pollForRunning(userGuid: String, authToken: String) async {
        let maxAttempts = 12 // 60 seconds with 5s interval
        let pollInterval: UInt64 = 5_000_000_000 // 5 seconds

        for _ in 0..<maxAttempts {
            try? await Task.sleep(nanoseconds: pollInterval)

            do {
                let status = try await apiClient.getVaultStatusAction(
                    userGuid: userGuid,
                    cognitoToken: authToken
                )

                if status.instanceStatus == "running" {
                    vaultStatus = .running
                    return
                } else if status.instanceStatus == "stopped" || status.instanceStatus == "terminated" {
                    vaultStatus = .stopped
                    return
                }
                // Still starting, continue polling
            } catch {
                // Continue polling on error
            }
        }

        // Timeout - check final status
        await refreshStatus()
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
