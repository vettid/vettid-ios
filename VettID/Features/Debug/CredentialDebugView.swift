import SwiftUI

#if DEBUG

// MARK: - Credential Debug View

/// Debug screen for inspecting credential state and testing operations.
/// Only available in DEBUG builds.
struct CredentialDebugView: View {
    @StateObject private var viewModel = CredentialDebugViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            // Credential Status
            Section("Credential Status") {
                StatusRow(
                    title: "Has Credential",
                    value: viewModel.hasCredential ? "Yes" : "No",
                    valueColor: viewModel.hasCredential ? .green : .red
                )

                if let userGuid = viewModel.userGuid {
                    StatusRow(
                        title: "User GUID",
                        value: String(userGuid.prefix(12)) + "...",
                        isMonospace: true
                    )
                }

                if let vaultStatus = viewModel.vaultStatus {
                    StatusRow(
                        title: "Vault Status",
                        value: vaultStatus
                    )
                }

                if let createdAt = viewModel.createdAt {
                    StatusRow(
                        title: "Created",
                        value: createdAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }

                if let lastUsed = viewModel.lastUsedAt {
                    StatusRow(
                        title: "Last Used",
                        value: lastUsed.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }

            // LAT (Ledger Auth Token) Section
            if let lat = viewModel.ledgerAuthToken {
                Section("Ledger Auth Token (LAT)") {
                    StatusRow(
                        title: "LAT ID",
                        value: String(lat.latId.prefix(16)) + "...",
                        isMonospace: true
                    )

                    StatusRow(
                        title: "Version",
                        value: String(lat.version)
                    )

                    StatusRow(
                        title: "Token",
                        value: String(lat.token.prefix(20)) + "...",
                        isMonospace: true
                    )
                }
            }

            // UTK (User Transaction Keys) Section
            Section("User Transaction Keys (UTK)") {
                StatusRow(
                    title: "Total Keys",
                    value: String(viewModel.totalUTKCount)
                )

                StatusRow(
                    title: "Unused Keys",
                    value: String(viewModel.unusedUTKCount),
                    valueColor: viewModel.unusedUTKCount > 0 ? .green : .orange
                )

                StatusRow(
                    title: "Used Keys",
                    value: String(viewModel.usedUTKCount)
                )

                if viewModel.unusedUTKCount == 0 && viewModel.hasCredential {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("No unused keys - authentication will request new keys")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Enclave Public Key Section
            if let enclaveKey = viewModel.enclavePublicKey {
                Section("Enclave Public Key") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Identity Key (Base64)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(enclaveKey)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3)
                            .textSelection(.enabled)

                        Button {
                            UIPasteboard.general.string = enclaveKey
                        } label: {
                            Label("Copy to Clipboard", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // Sealed Credential Section
            if let sealedCred = viewModel.sealedCredential {
                Section("Sealed Credential") {
                    VStack(alignment: .leading, spacing: 8) {
                        StatusRow(
                            title: "Size",
                            value: "\(sealedCred.count) bytes (Base64)"
                        )

                        Text(sealedCred.prefix(60) + "...")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            // Backup Key Section
            if let backupKey = viewModel.backupKey {
                Section("Backup Key") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(backupKey.prefix(32)) + "...")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)

                        Button {
                            UIPasteboard.general.string = backupKey
                        } label: {
                            Label("Copy to Clipboard", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // Actions Section
            Section("Actions") {
                Button(role: .destructive) {
                    viewModel.clearCredentials()
                } label: {
                    Label("Clear All Credentials", systemImage: "trash")
                }
                .disabled(!viewModel.hasCredential)

                Button {
                    viewModel.refreshData()
                } label: {
                    Label("Refresh Data", systemImage: "arrow.clockwise")
                }
            }

            // Debug Info Section
            Section("Debug Info") {
                StatusRow(
                    title: "Keychain Service",
                    value: "com.vettid.credentials",
                    isMonospace: true
                )

                StatusRow(
                    title: "Build Config",
                    value: "DEBUG"
                )
            }
        }
        .navigationTitle("Credential Debug")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.refreshData()
        }
        .alert("Credentials Cleared", isPresented: $viewModel.showClearedAlert) {
            Button("OK") { }
        } message: {
            Text("All credentials have been removed from the keychain.")
        }
    }
}

// MARK: - Status Row

private struct StatusRow: View {
    let title: String
    let value: String
    var valueColor: Color = .primary
    var isMonospace: Bool = false

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            if isMonospace {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(valueColor)
            } else {
                Text(value)
                    .foregroundStyle(valueColor)
            }
        }
    }
}

// MARK: - View Model

@MainActor
final class CredentialDebugViewModel: ObservableObject {
    // Published State
    @Published private(set) var hasCredential: Bool = false
    @Published private(set) var userGuid: String?
    @Published private(set) var vaultStatus: String?
    @Published private(set) var createdAt: Date?
    @Published private(set) var lastUsedAt: Date?
    @Published private(set) var ledgerAuthToken: StoredLAT?
    @Published private(set) var totalUTKCount: Int = 0
    @Published private(set) var unusedUTKCount: Int = 0
    @Published private(set) var usedUTKCount: Int = 0
    @Published private(set) var enclavePublicKey: String?
    @Published private(set) var sealedCredential: String?
    @Published private(set) var backupKey: String?
    @Published var showClearedAlert: Bool = false

    // Dependencies
    private let credentialStore = CredentialStore()

    // MARK: - Public Methods

    func refreshData() {
        hasCredential = credentialStore.hasStoredCredential()

        do {
            if let credential = try credentialStore.retrieveFirst(authenticationPrompt: "Access credentials for debug") {
                userGuid = credential.userGuid
                vaultStatus = credential.vaultStatus
                createdAt = credential.createdAt
                lastUsedAt = credential.lastUsedAt
                ledgerAuthToken = credential.ledgerAuthToken
                totalUTKCount = credential.transactionKeys.count
                unusedUTKCount = credential.unusedKeyCount
                usedUTKCount = credential.transactionKeys.filter { $0.isUsed }.count
                enclavePublicKey = credential.enclavePublicKey
                sealedCredential = credential.sealedCredential
                backupKey = credential.backupKey
            } else {
                clearLocalState()
            }
        } catch {
            print("[CredentialDebug] Error retrieving credential: \(error)")
            clearLocalState()
        }
    }

    func clearCredentials() {
        do {
            try credentialStore.deleteAll()
            clearLocalState()
            showClearedAlert = true
        } catch {
            print("[CredentialDebug] Error clearing credentials: \(error)")
        }
    }

    private func clearLocalState() {
        userGuid = nil
        vaultStatus = nil
        createdAt = nil
        lastUsedAt = nil
        ledgerAuthToken = nil
        totalUTKCount = 0
        unusedUTKCount = 0
        usedUTKCount = 0
        enclavePublicKey = nil
        sealedCredential = nil
        backupKey = nil
        hasCredential = false
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        CredentialDebugView()
    }
}

#endif
