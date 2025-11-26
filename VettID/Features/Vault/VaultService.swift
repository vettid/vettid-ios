import Foundation

/// Manages vault operations and status monitoring
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
    func startStatusMonitoring(vaultId: String, authToken: String) {
        stopStatusMonitoring()

        statusTask = Task {
            while !Task.isCancelled {
                await refreshStatus(vaultId: vaultId, authToken: authToken)
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
            }
        }
    }

    /// Stop polling vault status
    func stopStatusMonitoring() {
        statusTask?.cancel()
        statusTask = nil
    }

    /// Refresh vault status once
    func refreshStatus(vaultId: String, authToken: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await apiClient.getVaultStatus(vaultId: vaultId, authToken: authToken)
            status = parseStatus(from: response)
            error = nil
        } catch {
            self.error = VaultError.statusCheckFailed(error)
        }
    }

    private func parseStatus(from response: VaultStatusResponse) -> VaultStatus {
        switch response.status.lowercased() {
        case "pending_enrollment":
            return .pendingEnrollment
        case "provisioning":
            return .provisioning
        case "running":
            return .running(instanceId: response.instanceId ?? "unknown")
        case "stopped":
            return .stopped
        case "terminated":
            return .terminated
        default:
            return .stopped
        }
    }

    // MARK: - Vault Actions

    /// Start the vault instance
    func startVault(vaultId: String, authToken: String) async throws {
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await apiClient.vaultAction(
                vaultId: vaultId,
                action: .start,
                authToken: authToken
            )

            if !response.success {
                throw VaultError.actionFailed(response.message)
            }

            status = .provisioning

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
    func stopVault(vaultId: String, authToken: String) async throws {
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await apiClient.vaultAction(
                vaultId: vaultId,
                action: .stop,
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

    /// Restart the vault instance
    func restartVault(vaultId: String, authToken: String) async throws {
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await apiClient.vaultAction(
                vaultId: vaultId,
                action: .restart,
                authToken: authToken
            )

            if !response.success {
                throw VaultError.actionFailed(response.message)
            }

            status = .provisioning

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

// MARK: - Vault Status Display

extension VaultStatus {
    var displayName: String {
        switch self {
        case .pendingEnrollment:
            return "Pending Enrollment"
        case .provisioning:
            return "Starting..."
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
        case .provisioning:
            return "arrow.clockwise"
        case .running:
            return "checkmark.circle.fill"
        case .stopped:
            return "stop.circle.fill"
        case .terminated:
            return "xmark.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .pendingEnrollment:
            return "orange"
        case .provisioning:
            return "blue"
        case .running:
            return "green"
        case .stopped:
            return "gray"
        case .terminated:
            return "red"
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

// MARK: - Errors

enum VaultError: Error {
    case statusCheckFailed(Error)
    case actionFailed(String)
    case notAuthenticated
    case vaultNotFound

    var localizedDescription: String {
        switch self {
        case .statusCheckFailed(let error):
            return "Failed to check vault status: \(error.localizedDescription)"
        case .actionFailed(let message):
            return "Vault action failed: \(message)"
        case .notAuthenticated:
            return "Please authenticate to manage your vault"
        case .vaultNotFound:
            return "Vault not found. Please complete enrollment first."
        }
    }
}
