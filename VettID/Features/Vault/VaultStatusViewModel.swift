import Foundation
import SwiftUI

/// Manages vault status display and actions
@MainActor
final class VaultStatusViewModel: ObservableObject {

    // MARK: - Published State

    @Published var state: VaultViewState = .loading
    @Published var vaultInfo: VaultInfo?
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    // MARK: - Status Details

    @Published var lastSyncAt: Date?
    @Published var lastBackupAt: Date?
    @Published var unusedKeyCount: Int = 0
    @Published var healthStatus: VaultHealthStatus = .unknown

    // MARK: - Dependencies

    private let credentialStore = CredentialStore()
    private let vaultService = VaultService()
    private var refreshTask: Task<Void, Never>?

    // MARK: - View State

    enum VaultViewState: Equatable {
        case loading
        case notEnrolled
        case enrolled(VaultStatusInfo)
        case error(message: String, retryable: Bool)

        var title: String {
            switch self {
            case .loading:
                return "Loading..."
            case .notEnrolled:
                return "Set Up Your Vault"
            case .enrolled(let info):
                return info.status.displayName
            case .error:
                return "Error"
            }
        }
    }

    // MARK: - Vault Info Model

    struct VaultInfo: Equatable {
        let userGuid: String
        let status: VaultLifecycleStatus
        let enrolledAt: Date?
        let instanceId: String?
        let region: String?
        let lastBackup: Date?
        let health: VaultHealthStatus
    }

    struct VaultStatusInfo: Equatable {
        let status: VaultLifecycleStatus
        let instanceId: String?
        let health: VaultHealthStatus
    }

    // MARK: - Initialization

    init() {
        loadInitialState()
    }

    // MARK: - Load State

    func loadInitialState() {
        state = .loading

        do {
            guard let credential = try credentialStore.retrieveFirst() else {
                state = .notEnrolled
                return
            }

            // Get vault status from stored credential
            let vaultStatus = parseVaultStatus(credential.vaultStatus)
            unusedKeyCount = credential.unusedKeyCount

            let statusInfo = VaultStatusInfo(
                status: vaultStatus,
                instanceId: nil,
                health: .unknown
            )

            vaultInfo = VaultInfo(
                userGuid: credential.userGuid,
                status: vaultStatus,
                enrolledAt: credential.createdAt,
                instanceId: nil,
                region: nil,
                lastBackup: nil,
                health: .unknown
            )

            state = .enrolled(statusInfo)

        } catch {
            handleError(error, retryable: true)
        }
    }

    // MARK: - Refresh Status

    /// Refresh vault status from server
    func refreshStatus(authToken: String = "") async {
        guard case .enrolled = state else {
            return
        }

        do {
            guard let credential = try credentialStore.retrieveFirst() else {
                state = .notEnrolled
                return
            }

            // In a real implementation, we would call the API
            // For now, use stored data
            // let response = try await apiClient.getVaultStatus(...)

            unusedKeyCount = credential.unusedKeyCount
            lastSyncAt = Date()

            // Check if we need to warn about low keys
            if unusedKeyCount < 5 {
                healthStatus = .warning
            } else {
                healthStatus = .healthy
            }

        } catch {
            handleError(error, retryable: true)
        }
    }

    // MARK: - Vault Actions

    /// Start the vault
    func startVault(authToken: String) async {
        guard var currentInfo = vaultInfo else { return }

        do {
            // Update to provisioning state
            currentInfo = VaultInfo(
                userGuid: currentInfo.userGuid,
                status: .provisioning,
                enrolledAt: currentInfo.enrolledAt,
                instanceId: nil,
                region: currentInfo.region,
                lastBackup: currentInfo.lastBackup,
                health: .unknown
            )
            vaultInfo = currentInfo
            state = .enrolled(VaultStatusInfo(
                status: .provisioning,
                instanceId: nil,
                health: .unknown
            ))

            try await vaultService.startVault(authToken: authToken)

            // Poll for running status
            await pollForStatus(.running, authToken: authToken)

        } catch {
            handleError(error, retryable: true)
        }
    }

    /// Stop the vault
    func stopVault(authToken: String) async {
        guard var currentInfo = vaultInfo else { return }

        do {
            try await vaultService.stopVault(authToken: authToken)

            currentInfo = VaultInfo(
                userGuid: currentInfo.userGuid,
                status: .stopped,
                enrolledAt: currentInfo.enrolledAt,
                instanceId: currentInfo.instanceId,
                region: currentInfo.region,
                lastBackup: Date(),  // Backup triggered on stop
                health: .unknown
            )
            vaultInfo = currentInfo
            state = .enrolled(VaultStatusInfo(
                status: .stopped,
                instanceId: currentInfo.instanceId,
                health: .unknown
            ))

        } catch {
            handleError(error, retryable: true)
        }
    }

    /// Trigger manual sync
    func syncVault(authToken: String) async {
        // Sync implementation - would call API
        lastSyncAt = Date()
    }

    // MARK: - Background Polling

    /// Start automatic status refresh
    func startAutoRefresh(authToken: String, interval: TimeInterval = 30) {
        stopAutoRefresh()

        refreshTask = Task {
            while !Task.isCancelled {
                await refreshStatus(authToken: authToken)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Stop automatic status refresh
    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Private Helpers

    private func pollForStatus(_ targetStatus: VaultLifecycleStatus, authToken: String) async {
        for _ in 0..<30 {  // Poll for up to 5 minutes
            try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
            await refreshStatus(authToken: authToken)

            if let info = vaultInfo, info.status == targetStatus {
                return
            }
        }
    }

    private func parseVaultStatus(_ statusString: String?) -> VaultLifecycleStatus {
        guard let status = statusString?.uppercased() else {
            return .enrolled
        }

        switch status {
        case "PENDING_ENROLLMENT":
            return .pendingEnrollment
        case "ENROLLED":
            return .enrolled
        case "PROVISIONING":
            return .provisioning
        case "RUNNING":
            return .running
        case "STOPPED":
            return .stopped
        case "TERMINATED":
            return .terminated
        default:
            return .enrolled
        }
    }

    private func handleError(_ error: Error, retryable: Bool) {
        let message: String
        if let vaultError = error as? VaultError {
            message = vaultError.localizedDescription
        } else {
            message = error.localizedDescription
        }

        errorMessage = message
        showError = true
        state = .error(message: message, retryable: retryable)
    }

    // MARK: - Reset

    func reset() {
        state = .loading
        vaultInfo = nil
        errorMessage = nil
        showError = false
        lastSyncAt = nil
        lastBackupAt = nil
        unusedKeyCount = 0
        healthStatus = .unknown
        stopAutoRefresh()
    }
}

// MARK: - Vault Lifecycle Status

enum VaultLifecycleStatus: String, Equatable, CaseIterable {
    case pendingEnrollment = "pending_enrollment"
    case enrolled = "enrolled"
    case provisioning = "provisioning"
    case running = "running"
    case stopped = "stopped"
    case terminated = "terminated"

    var displayName: String {
        switch self {
        case .pendingEnrollment:
            return "Pending Enrollment"
        case .enrolled:
            return "Enrolled"
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
        case .enrolled:
            return "checkmark.seal"
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

    var statusColor: Color {
        switch self {
        case .pendingEnrollment:
            return .orange
        case .enrolled:
            return .blue
        case .provisioning:
            return .yellow
        case .running:
            return .green
        case .stopped:
            return .gray
        case .terminated:
            return .red
        }
    }

    var canStart: Bool {
        self == .enrolled || self == .stopped
    }

    var canStop: Bool {
        self == .running
    }
}

// MARK: - Vault Health Status

enum VaultHealthStatus: String, Equatable {
    case healthy = "healthy"
    case warning = "warning"
    case critical = "critical"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .healthy:
            return "Healthy"
        case .warning:
            return "Warning"
        case .critical:
            return "Critical"
        case .unknown:
            return "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .healthy:
            return "heart.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .critical:
            return "exclamationmark.octagon.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .healthy:
            return .green
        case .warning:
            return .yellow
        case .critical:
            return .red
        case .unknown:
            return .gray
        }
    }
}
