import Foundation
import Combine

/// ViewModel for monitoring vault health status
@MainActor
final class VaultHealthViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var healthState: VaultHealthState = .loading
    @Published private(set) var isPolling: Bool = false

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let natsConnectionManager: NatsConnectionManager
    private let authTokenProvider: () -> String?

    // MARK: - Polling Configuration

    private let pollingInterval: TimeInterval = 30  // 30 seconds
    private let provisioningPollInterval: TimeInterval = 2  // 2 seconds during provisioning
    private let maxProvisioningAttempts = 60  // 2 minutes max

    // MARK: - Task Management

    private var healthCheckTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        natsConnectionManager: NatsConnectionManager? = nil,
        authTokenProvider: @escaping () -> String?
    ) {
        self.apiClient = apiClient
        self.natsConnectionManager = natsConnectionManager ?? NatsConnectionManager()
        self.authTokenProvider = authTokenProvider
    }

    // MARK: - Health Monitoring

    /// Start periodic health monitoring
    func startHealthMonitoring() {
        guard !isPolling else { return }

        isPolling = true
        healthCheckTask?.cancel()
        healthCheckTask = Task {
            while !Task.isCancelled {
                await checkHealth()
                try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
            }
        }
    }

    /// Stop health monitoring
    func stopHealthMonitoring() {
        isPolling = false
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }

    /// Perform a single health check
    func checkHealth() async {
        guard let authToken = authTokenProvider() else {
            healthState = .error("Not authenticated")
            return
        }

        do {
            let health = try await apiClient.getVaultHealth(authToken: authToken)
            healthState = .loaded(VaultHealthInfo(from: health))
        } catch let error as APIError {
            switch error {
            case .httpError(404):
                healthState = .notProvisioned
            default:
                healthState = .error(error.localizedDescription)
            }
        } catch {
            healthState = .error(error.localizedDescription)
        }
    }

    // MARK: - Vault Lifecycle

    /// Provision a new vault instance
    func provisionVault() async {
        guard let authToken = authTokenProvider() else {
            healthState = .error("Not authenticated")
            return
        }

        healthState = .provisioning(progress: 0, status: "Starting provisioning...")

        do {
            let provision = try await apiClient.provisionVault(authToken: authToken)
            await pollForProvisioning(instanceId: provision.instanceId, authToken: authToken)
        } catch {
            healthState = .error("Provisioning failed: \(error.localizedDescription)")
        }
    }

    /// Initialize the vault after provisioning
    func initializeVault() async {
        guard let authToken = authTokenProvider() else {
            healthState = .error("Not authenticated")
            return
        }

        healthState = .provisioning(progress: 0.8, status: "Initializing vault services...")

        do {
            let initResponse = try await apiClient.initializeVault(authToken: authToken)

            if initResponse.status == "initialized" {
                healthState = .provisioning(progress: 1.0, status: "Vault ready!")
                // Transition to loaded state after brief delay
                try? await Task.sleep(nanoseconds: 500_000_000)
                await checkHealth()
            } else {
                healthState = .error("Initialization failed: \(initResponse.status)")
            }
        } catch {
            healthState = .error("Initialization failed: \(error.localizedDescription)")
        }
    }

    /// Stop the vault (preserves state)
    func stopVault() async {
        guard let authToken = authTokenProvider() else {
            healthState = .error("Not authenticated")
            return
        }

        do {
            let response = try await apiClient.stopVaultInstance(authToken: authToken)

            if response.status == "stopped" || response.status == "stopping" {
                healthState = .stopped
            } else {
                healthState = .error("Stop failed: \(response.message)")
            }
        } catch {
            healthState = .error("Stop failed: \(error.localizedDescription)")
        }
    }

    /// Terminate the vault (full cleanup)
    func terminateVault() async {
        guard let authToken = authTokenProvider() else {
            healthState = .error("Not authenticated")
            return
        }

        do {
            let response = try await apiClient.terminateVault(authToken: authToken)

            if response.status == "terminated" || response.status == "terminating" {
                healthState = .notProvisioned
            } else {
                healthState = .error("Terminate failed: \(response.message)")
            }
        } catch {
            healthState = .error("Terminate failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Methods

    private func pollForProvisioning(instanceId: String, authToken: String) async {
        for attempt in 0..<maxProvisioningAttempts {
            if Task.isCancelled { return }

            let progress = Double(attempt) / Double(maxProvisioningAttempts) * 0.7 // Max 70% during provisioning

            do {
                try await Task.sleep(nanoseconds: UInt64(provisioningPollInterval * 1_000_000_000))

                let health = try await apiClient.getVaultHealth(authToken: authToken)

                switch health.status {
                case "healthy":
                    healthState = .loaded(VaultHealthInfo(from: health))
                    return

                case "degraded":
                    // Still initializing, update progress
                    healthState = .provisioning(progress: progress + 0.1, status: "Services starting...")

                default:
                    // Still provisioning
                    healthState = .provisioning(progress: progress, status: "Instance starting...")
                }
            } catch {
                // Still provisioning - instance not ready yet
                healthState = .provisioning(progress: progress, status: "Waiting for instance...")
            }
        }

        healthState = .error("Provisioning timed out after 2 minutes")
    }

    deinit {
        healthCheckTask?.cancel()
    }
}

// MARK: - Health State

enum VaultHealthState: Equatable {
    case loading
    case notProvisioned
    case provisioning(progress: Double, status: String)
    case stopped
    case loaded(VaultHealthInfo)
    case error(String)

    static func == (lhs: VaultHealthState, rhs: VaultHealthState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading),
             (.notProvisioned, .notProvisioned),
             (.stopped, .stopped):
            return true
        case (.provisioning(let p1, let s1), .provisioning(let p2, let s2)):
            return p1 == p2 && s1 == s2
        case (.loaded(let h1), .loaded(let h2)):
            return h1 == h2
        case (.error(let e1), .error(let e2)):
            return e1 == e2
        default:
            return false
        }
    }

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    var isProvisioning: Bool {
        if case .provisioning = self { return true }
        return false
    }

    var displayTitle: String {
        switch self {
        case .loading: return "Loading..."
        case .notProvisioned: return "No Vault"
        case .provisioning: return "Provisioning..."
        case .stopped: return "Stopped"
        case .loaded(let info): return info.status.displayName
        case .error: return "Error"
        }
    }
}

// MARK: - Health Info

struct VaultHealthInfo: Equatable {
    let status: HealthStatus
    let uptime: TimeInterval
    let localNatsConnected: Bool
    let localNatsConnections: Int
    let centralNatsConnected: Bool
    let centralNatsLatency: Int
    let vaultManagerRunning: Bool
    let vaultManagerMemoryMb: Int
    let vaultManagerCpuPercent: Float
    let handlersLoaded: Int
    let lastEventAt: Date?

    init(from response: VaultHealthResponse) {
        self.status = HealthStatus(rawValue: response.status) ?? .unhealthy
        self.uptime = TimeInterval(response.uptimeSeconds)
        self.localNatsConnected = response.localNats.status == "running"
        self.localNatsConnections = response.localNats.connections
        self.centralNatsConnected = response.centralNats.status == "connected"
        self.centralNatsLatency = response.centralNats.latencyMs
        self.vaultManagerRunning = response.vaultManager.status == "running"
        self.vaultManagerMemoryMb = response.vaultManager.memoryMb
        self.vaultManagerCpuPercent = response.vaultManager.cpuPercent
        self.handlersLoaded = response.vaultManager.handlersLoaded
        self.lastEventAt = response.lastEventAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    var formattedUptime: String {
        let hours = Int(uptime) / 3600
        let minutes = (Int(uptime) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var latencyDescription: String {
        if centralNatsLatency < 50 {
            return "Excellent"
        } else if centralNatsLatency < 100 {
            return "Good"
        } else if centralNatsLatency < 200 {
            return "Fair"
        } else {
            return "Poor"
        }
    }
}

// MARK: - Health Status

enum HealthStatus: String {
    case healthy
    case degraded
    case unhealthy

    var displayName: String {
        rawValue.capitalized
    }

    var isOperational: Bool {
        self == .healthy || self == .degraded
    }
}
