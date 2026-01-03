import Foundation
import Combine

/// ViewModel for monitoring Nitro Enclave vault health status
@MainActor
final class VaultHealthViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var healthState: VaultHealthState = .loading
    @Published private(set) var isPolling: Bool = false

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let natsConnectionManager: NatsConnectionManager
    private let authTokenProvider: () -> String?
    private let userGuidProvider: () -> String?

    // MARK: - Polling Configuration

    private let pollingInterval: TimeInterval = 30  // 30 seconds

    // MARK: - Task Management

    private var healthCheckTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        natsConnectionManager: NatsConnectionManager? = nil,
        authTokenProvider: @escaping () -> String?,
        userGuidProvider: @escaping () -> String? = { nil }
    ) {
        self.apiClient = apiClient
        self.authTokenProvider = authTokenProvider
        self.userGuidProvider = userGuidProvider
        self.natsConnectionManager = natsConnectionManager ?? NatsConnectionManager(
            userGuidProvider: userGuidProvider
        )
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
                healthState = .notEnrolled
            default:
                healthState = .error(error.localizedDescription)
            }
        } catch {
            healthState = .error(error.localizedDescription)
        }
    }

    // MARK: - Status Helpers

    /// Returns true if vault needs attention (unhealthy or error state)
    var needsAttention: Bool {
        switch healthState {
        case .error:
            return true
        case .loaded(let info):
            return info.status == .unhealthy
        default:
            return false
        }
    }

    /// Get a short status summary for home screen display
    var statusSummary: String {
        switch healthState {
        case .loading:
            return "Checking..."
        case .notEnrolled:
            return "Not enrolled"
        case .loaded(let info):
            return info.status.displayName
        case .error(let message):
            return "Error: \(message)"
        }
    }

    /// Whether the vault is running and healthy
    var isHealthy: Bool {
        if case .loaded(let info) = healthState {
            return info.status == .healthy
        }
        return false
    }

    /// Whether the vault is currently operational (healthy or degraded)
    var isOperational: Bool {
        if case .loaded(let info) = healthState {
            return info.status.isOperational
        }
        return false
    }

    /// Terminate the vault
    func terminateVault() async {
        guard let authToken = authTokenProvider() else {
            healthState = .error("Not authenticated")
            return
        }

        do {
            let response = try await apiClient.terminateVault(authToken: authToken)

            if response.status == "terminated" || response.status == "terminating" {
                healthState = .notEnrolled
            } else {
                healthState = .error("Terminate failed: \(response.message)")
            }
        } catch {
            healthState = .error("Terminate failed: \(error.localizedDescription)")
        }
    }

    deinit {
        healthCheckTask?.cancel()
    }
}

// MARK: - Health State (Nitro Enclave - simplified)

enum VaultHealthState: Equatable {
    case loading
    case notEnrolled           // User not enrolled yet
    case loaded(VaultHealthInfo)   // Enclave is always ready when enrolled
    case error(String)

    static func == (lhs: VaultHealthState, rhs: VaultHealthState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading),
             (.notEnrolled, .notEnrolled):
            return true
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

    var displayTitle: String {
        switch self {
        case .loading: return "Loading..."
        case .notEnrolled: return "Not Enrolled"
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
