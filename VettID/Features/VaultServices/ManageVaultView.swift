import SwiftUI

struct ManageVaultView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: ManageVaultViewModel

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
                vaultInfoSection
                dangerZoneSection
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
                    Text("Enclave Status")
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
            Text("Your vault runs in a secure Nitro Enclave with hardware-level isolation.")
        }
    }

    // MARK: - No Vault Section

    private var noVaultSection: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)

                Text("No Vault Enrolled")
                    .font(.headline)

                Text("Complete enrollment to activate your secure enclave vault.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    // MARK: - Vault Info Section

    private var vaultInfoSection: some View {
        Section("Vault Information") {
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
                Text("Type")
                Spacer()
                Text("Nitro Enclave")
                    .foregroundStyle(.secondary)
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

                        Text("Permanently delete your vault")
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

// MARK: - Vault Server Status (Nitro Enclave)

enum VaultServerStatus: Equatable {
    case unknown
    case loading
    case enclaveReady     // Nitro Enclave is always ready
    case terminated
    case error(String)

    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .loading: return "Checking..."
        case .enclaveReady: return "Enclave Ready"
        case .terminated: return "Terminated"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var color: Color {
        switch self {
        case .enclaveReady: return .green
        case .terminated: return .gray
        case .loading: return .blue
        case .error: return .red
        case .unknown: return .gray
        }
    }

    static func == (lhs: VaultServerStatus, rhs: VaultServerStatus) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown), (.loading, .loading),
             (.enclaveReady, .enclaveReady), (.terminated, .terminated):
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

    /// Refresh vault status
    func refreshStatus() async {
        guard let authToken = authTokenProvider() else {
            // No auth - can't check status
            return
        }

        vaultStatus = .loading

        do {
            let health = try await apiClient.getVaultHealth(authToken: authToken)
            switch health.status {
            case "healthy", "degraded", "ENCLAVE_READY":
                vaultStatus = .enclaveReady
            case "terminated":
                vaultStatus = .terminated
            default:
                vaultStatus = .enclaveReady  // Enclave is always ready
            }
        } catch {
            // Assume enclave is ready if we can't reach health endpoint
            vaultStatus = .enclaveReady
        }
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
            vaultStatus = .terminated
        } catch {
            errorMessage = "Failed to terminate vault: \(error.localizedDescription)"
        }

        isLoading = false
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
