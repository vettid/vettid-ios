import Foundation

/// Manages vault operations and status monitoring
///
/// Note: Vault operations are Phase 5 and not yet deployed on the backend.
/// The API endpoints will be available at:
/// - GET /member/vaults/{id}/status
/// - POST /member/vaults/{id}/start
/// - POST /member/vaults/{id}/stop
@MainActor
final class VaultService: ObservableObject {

    @Published var status: VaultStatus?
    @Published var isLoading = false
    @Published var error: VaultError?

    private let apiClient = APIClient()
    private let credentialStore = CredentialStore()
    private var statusTask: Task<Void, Never>?

    // MARK: - Status Monitoring

    /// Start polling vault status
    func startStatusMonitoring(authToken: String) {
        guard let credential = try? credentialStore.retrieveFirst() else {
            error = .noCredential
            return
        }

        // Use vaultStatus from credential if available
        if let storedStatus = credential.vaultStatus {
            status = parseStatus(from: storedStatus)
        }

        stopStatusMonitoring()

        // Note: Vault status API not yet deployed
        // This will be enabled in Phase 5
        /*
        statusTask = Task {
            while !Task.isCancelled {
                await refreshStatus(authToken: authToken)
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
            }
        }
        */
    }

    /// Stop polling vault status
    func stopStatusMonitoring() {
        statusTask?.cancel()
        statusTask = nil
    }

    /// Refresh vault status once
    func refreshStatus(authToken: String) async {
        guard let credential = try? credentialStore.retrieveFirst() else {
            error = .noCredential
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await apiClient.getVaultStatus(
                vaultId: credential.userGuid,
                authToken: authToken
            )
            status = parseStatus(from: response.status)
            error = nil
        } catch {
            self.error = VaultError.statusCheckFailed(error)
        }
    }

    private func parseStatus(from statusString: String) -> VaultStatus {
        switch statusString.uppercased() {
        case "PENDING_ENROLLMENT", "PENDING-ENROLLMENT":
            return .pendingEnrollment
        case "PENDING_PROVISION", "PENDING-PROVISION":
            return .pendingProvision
        case "PROVISIONING":
            return .provisioning(progress: nil)
        case "INITIALIZING":
            return .initializing
        case "RUNNING":
            return .running(instanceId: "")
        case "STOPPED":
            return .stopped
        case "TERMINATED":
            return .terminated
        default:
            return .stopped
        }
    }

    // MARK: - Vault Actions (Phase 5 - Not Yet Deployed)

    /// Start the vault instance
    func startVault(authToken: String) async throws {
        guard let credential = try? credentialStore.retrieveFirst() else {
            throw VaultError.noCredential
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await apiClient.startVault(
                vaultId: credential.userGuid,
                authToken: authToken
            )

            if !response.success {
                throw VaultError.actionFailed(response.message)
            }

            status = .provisioning(progress: nil)

        } catch let error as VaultError {
            self.error = error
            throw error
        } catch {
            let wrappedError = VaultError.actionFailed(error.localizedDescription)
            self.error = wrappedError
            throw wrappedError
        }
    }

    /// Stop the vault instance
    func stopVault(authToken: String) async throws {
        guard let credential = try? credentialStore.retrieveFirst() else {
            throw VaultError.noCredential
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await apiClient.stopVault(
                vaultId: credential.userGuid,
                authToken: authToken
            )

            if !response.success {
                throw VaultError.actionFailed(response.message)
            }

            status = .stopped

        } catch let error as VaultError {
            self.error = error
            throw error
        } catch {
            let wrappedError = VaultError.actionFailed(error.localizedDescription)
            self.error = wrappedError
            throw wrappedError
        }
    }
}

// MARK: - Vault Status

enum VaultStatus: Equatable {
    case pendingEnrollment
    case pendingProvision      // Enrollment complete, waiting for vault provision
    case provisioning(progress: Double?)  // EC2 instance being created
    case initializing          // Vault software starting up
    case running(instanceId: String)
    case stopped
    case terminated

    var displayName: String {
        switch self {
        case .pendingEnrollment:
            return "Pending Enrollment"
        case .pendingProvision:
            return "Ready to Provision"
        case .provisioning:
            return "Provisioning..."
        case .initializing:
            return "Initializing..."
        case .running:
            return "Running"
        case .stopped:
            return "Stopped"
        case .terminated:
            return "Terminated"
        }
    }

    var systemImage: String {
        switch self {
        case .pendingEnrollment:
            return "hourglass"
        case .pendingProvision:
            return "externaldrive.badge.plus"
        case .provisioning, .initializing:
            return "arrow.clockwise"
        case .running:
            return "checkmark.circle.fill"
        case .stopped:
            return "stop.circle.fill"
        case .terminated:
            return "xmark.circle.fill"
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    var isStarting: Bool {
        switch self {
        case .provisioning, .initializing:
            return true
        default:
            return false
        }
    }
}

// MARK: - Errors

enum VaultError: Error, LocalizedError {
    case statusCheckFailed(Error)
    case actionFailed(String)
    case notAuthenticated
    case noCredential

    var errorDescription: String? {
        switch self {
        case .statusCheckFailed(let error):
            return "Failed to check vault status: \(error.localizedDescription)"
        case .actionFailed(let message):
            return "Vault action failed: \(message)"
        case .notAuthenticated:
            return "Please authenticate to manage your vault"
        case .noCredential:
            return "No credential found. Please complete enrollment first."
        }
    }
}
