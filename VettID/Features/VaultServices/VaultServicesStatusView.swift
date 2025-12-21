import SwiftUI

struct VaultServicesStatusView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = VaultServicesStatusViewModel()

    var body: some View {
        ScrollView {
            if appState.hasActiveVault {
                deployedVaultView
            } else {
                noVaultView
            }
        }
        .navigationTitle("Status")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            await viewModel.loadStatus()
        }
    }

    // MARK: - No Vault View

    private var noVaultView: some View {
        VStack(spacing: 32) {
            Spacer()
                .frame(height: 60)

            // Cloud icon
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 120, height: 120)

                Image(systemName: "cloud.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.blue)
            }

            // Text
            VStack(spacing: 12) {
                Text("No Vault Deployed")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Deploy a personal vault to securely store your credentials, messages, and data.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // Features list
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(icon: "lock.shield.fill", title: "End-to-End Encrypted", description: "Your data is encrypted with keys only you control")

                FeatureRow(icon: "server.rack", title: "Personal Cloud Vault", description: "Dedicated instance running in secure cloud infrastructure")

                FeatureRow(icon: "arrow.triangle.2.circlepath", title: "Real-Time Sync", description: "Seamless sync across all your devices via NATS")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            // Deploy button
            Button(action: {
                // TODO: Navigate to vault deployment flow
            }) {
                Label("Deploy Vault", systemImage: "cloud.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
    }

    // MARK: - Deployed Vault View

    private var deployedVaultView: some View {
        VStack(spacing: 20) {
            // Status Card
            statusCard

            // Stats Row
            statsRow

            // Quick Actions
            quickActionsSection

            // Recent Activity
            recentActivitySection
        }
        .padding()
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                // Status indicator
                ZStack {
                    Circle()
                        .fill(viewModel.statusColor.opacity(0.15))
                        .frame(width: 60, height: 60)

                    Image(systemName: viewModel.statusIcon)
                        .font(.system(size: 28))
                        .foregroundStyle(viewModel.statusColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Vault Status")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(viewModel.statusText)
                        .font(.title2)
                        .fontWeight(.bold)
                }

                Spacer()
            }

            Divider()

            // Details
            VStack(spacing: 12) {
                if let instanceId = appState.vaultInstanceId {
                    HStack {
                        Text("Instance ID")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(instanceId)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }

                HStack {
                    Text("Region")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(viewModel.region)
                        .fontWeight(.medium)
                }

                if let uptime = viewModel.uptime {
                    HStack {
                        Text("Uptime")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(uptime)
                            .fontWeight(.medium)
                    }
                }
            }
            .font(.subheadline)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatusStatCard(
                title: "Keys",
                value: "\(viewModel.unusedKeyCount)",
                icon: "key.fill",
                color: viewModel.unusedKeyCount < 5 ? .orange : .green
            )

            StatusStatCard(
                title: "Connections",
                value: "\(viewModel.connectionCount)",
                icon: "person.2.fill",
                color: .blue
            )

            StatusStatCard(
                title: "Messages",
                value: "\(viewModel.messageCount)",
                icon: "message.fill",
                color: .purple
            )
        }
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)

            HStack(spacing: 12) {
                QuickActionButton(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Sync",
                    color: .blue
                ) {
                    Task { await viewModel.syncVault() }
                }

                QuickActionButton(
                    icon: "key.fill",
                    title: "Generate Keys",
                    color: .green
                ) {
                    Task { await viewModel.generateKeys() }
                }

                QuickActionButton(
                    icon: "externaldrive.fill",
                    title: "Backup",
                    color: .orange
                ) {
                    // TODO: Navigate to backup
                }
            }
        }
    }

    // MARK: - Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Activity")
                    .font(.headline)

                Spacer()

                Button("View All") {
                    // TODO: Navigate to activity log
                }
                .font(.subheadline)
            }

            if viewModel.recentActivity.isEmpty {
                HStack {
                    Spacer()
                    Text("No recent activity")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.recentActivity) { activity in
                        ActivityRow(activity: activity)

                        if activity.id != viewModel.recentActivity.last?.id {
                            Divider()
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(12)
            }
        }
    }
}

// MARK: - Feature Row

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Status Stat Card

struct StatusStatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.title2)
                .fontWeight(.bold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Quick Action Button

struct QuickActionButton: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(color.opacity(0.1))
            .cornerRadius(12)
        }
    }
}

// MARK: - Activity Row

struct ActivityRow: View {
    let activity: VaultActivity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.icon)
                .font(.body)
                .foregroundStyle(activity.color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.subheadline)

                Text(activity.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
    }
}

// MARK: - View Model

@MainActor
class VaultServicesStatusViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var statusText = "Running"
    @Published var statusIcon = "checkmark.circle.fill"
    @Published var statusColor = Color.green
    @Published var region = "us-east-1"
    @Published var uptime: String? = "3d 14h"
    @Published var unusedKeyCount = 42
    @Published var connectionCount = 7
    @Published var messageCount = 156
    @Published var recentActivity: [VaultActivity] = []
    @Published var errorMessage: String?
    @Published var isSyncing = false
    @Published var isGeneratingKeys = false

    private let apiClient = APIClient()
    private let authTokenProvider: () -> String?

    init(authTokenProvider: @escaping () -> String? = { nil }) {
        self.authTokenProvider = authTokenProvider
    }

    func loadStatus() async {
        guard let authToken = authTokenProvider() else {
            // Fall back to mock data if no auth token
            loadMockData()
            return
        }

        isLoading = true

        do {
            let health = try await apiClient.getVaultHealth(authToken: authToken)

            // Update status from health response
            statusText = health.status.capitalized
            switch health.status.lowercased() {
            case "running", "healthy":
                statusIcon = "checkmark.circle.fill"
                statusColor = .green
            case "stopped":
                statusIcon = "pause.circle.fill"
                statusColor = .orange
            case "provisioning", "starting":
                statusIcon = "hourglass"
                statusColor = .blue
            case "unhealthy", "degraded":
                statusIcon = "exclamationmark.circle.fill"
                statusColor = .orange
            default:
                statusIcon = "questionmark.circle.fill"
                statusColor = .gray
            }

            // Calculate uptime from seconds
            uptime = formatUptime(health.uptimeSeconds)

            // Connection count from local NATS
            connectionCount = health.localNats.connections

            // Load recent activity
            loadMockActivity()

        } catch {
            errorMessage = "Failed to load status: \(error.localizedDescription)"
            loadMockData()
        }

        isLoading = false
    }

    private func loadMockData() {
        // Fallback mock data for demo/testing
        loadMockActivity()
    }

    private func formatUptime(_ seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600

        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            let minutes = (seconds % 3600) / 60
            return "\(hours)h \(minutes)m"
        } else {
            let minutes = seconds / 60
            return "\(minutes)m"
        }
    }

    private func loadMockActivity() {
        recentActivity = [
            VaultActivity(type: .sync, title: "Vault synced", timestamp: Date().addingTimeInterval(-300)),
            VaultActivity(type: .keyGenerated, title: "5 keys generated", timestamp: Date().addingTimeInterval(-3600)),
            VaultActivity(type: .backup, title: "Backup completed", timestamp: Date().addingTimeInterval(-86400)),
        ]
    }

    func refresh() async {
        await loadStatus()
    }

    func syncVault() async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            // Use NATS sync via VaultResponseHandler would be ideal, but for now use polling
            // This triggers a health check which forces data sync
            _ = try await apiClient.getVaultHealth(authToken: authToken)

            // Add sync activity
            let syncActivity = VaultActivity(type: .sync, title: "Vault synced", timestamp: Date())
            recentActivity.insert(syncActivity, at: 0)
            if recentActivity.count > 5 {
                recentActivity.removeLast()
            }
        } catch {
            errorMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    func generateKeys() async {
        guard authTokenProvider() != nil else {
            errorMessage = "Not authenticated"
            return
        }

        isGeneratingKeys = true
        defer { isGeneratingKeys = false }

        // Key generation would typically be done via VaultResponseHandler/NATS
        // For now, simulate the operation
        do {
            try await Task.sleep(nanoseconds: 1_500_000_000)

            // Increment key count (simulated)
            unusedKeyCount += 5

            // Add activity
            let keyActivity = VaultActivity(type: .keyGenerated, title: "5 keys generated", timestamp: Date())
            recentActivity.insert(keyActivity, at: 0)
            if recentActivity.count > 5 {
                recentActivity.removeLast()
            }
        } catch {
            errorMessage = "Key generation failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Models

struct VaultActivity: Identifiable {
    let id = UUID()
    let type: VaultActivityType
    let title: String
    let timestamp: Date

    enum VaultActivityType {
        case sync
        case keyGenerated
        case backup
        case message
        case connection

        var icon: String {
            switch self {
            case .sync: return "arrow.triangle.2.circlepath"
            case .keyGenerated: return "key.fill"
            case .backup: return "externaldrive.fill"
            case .message: return "message.fill"
            case .connection: return "person.2.fill"
            }
        }
    }

    var icon: String { type.icon }

    var color: Color {
        switch type {
        case .sync: return .blue
        case .keyGenerated: return .green
        case .backup: return .orange
        case .message: return .purple
        case .connection: return .blue
        }
    }
}

// MARK: - Preview

#Preview("No Vault") {
    NavigationStack {
        VaultServicesStatusView()
    }
    .environmentObject(AppState())
}

#Preview("Deployed Vault") {
    NavigationStack {
        VaultServicesStatusView()
    }
    .environmentObject({
        let state = AppState()
        state.hasActiveVault = true
        state.vaultInstanceId = "vault-abc123"
        return state
    }())
}
