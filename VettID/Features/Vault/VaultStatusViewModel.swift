import Foundation
import SwiftUI

/// Manages vault status display (Nitro Enclave - simplified)
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

            // With Nitro, vault is always running when enrolled
            let vaultStatus: VaultLifecycleStatus = .running
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

    /// Refresh vault status
    func refreshStatus(authToken: String = "") async {
        guard case .enrolled = state else {
            return
        }

        do {
            guard let credential = try credentialStore.retrieveFirst() else {
                state = .notEnrolled
                return
            }

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

    /// Trigger manual sync
    func syncVault(authToken: String) async {
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

// MARK: - Vault Lifecycle Status (Nitro Enclave - simplified)

enum VaultLifecycleStatus: String, Equatable, CaseIterable {
    case pendingEnrollment = "pending_enrollment"
    case enrolled = "enrolled"
    case running = "running"       // Enclave is always ready
    case terminated = "terminated"

    var displayName: String {
        switch self {
        case .pendingEnrollment:
            return "Pending Enrollment"
        case .enrolled:
            return "Enrolled"
        case .running:
            return "Enclave Ready"
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
        case .running:
            return "checkmark.shield.fill"
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
        case .running:
            return .green
        case .terminated:
            return .red
        }
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
