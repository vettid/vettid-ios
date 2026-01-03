import SwiftUI

/// Main vault health display view (Nitro Enclave)
struct VaultHealthView: View {
    @StateObject var viewModel: VaultHealthViewModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    contentView
                }
                .padding()
            }
            .navigationTitle("Enclave Health")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.isPolling {
                        Button(action: { viewModel.stopHealthMonitoring() }) {
                            Image(systemName: "pause.fill")
                        }
                    } else {
                        Button(action: { viewModel.startHealthMonitoring() }) {
                            Image(systemName: "play.fill")
                        }
                    }
                }
            }
        }
        .onAppear {
            viewModel.startHealthMonitoring()
        }
        .onDisappear {
            viewModel.stopHealthMonitoring()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.healthState {
        case .loading:
            LoadingView()

        case .notEnrolled:
            NotEnrolledView()

        case .loaded(let info):
            VaultHealthDetailsView(
                info: info,
                onTerminate: {
                    Task { await viewModel.terminateVault() }
                }
            )

        case .error(let message):
            ErrorView(message: message, onRetry: {
                Task { await viewModel.checkHealth() }
            })
        }
    }
}

// MARK: - Loading View

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .accessibilityIdentifier("vaultHealth.loading.spinner")
            Text("Checking enclave status...")
                .foregroundColor(.secondary)
                .accessibilityIdentifier("vaultHealth.loading.text")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 80)
        .accessibilityIdentifier("vaultHealth.loadingView")
    }
}

// MARK: - Not Enrolled View

struct NotEnrolledView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
                .accessibilityIdentifier("vaultHealth.notEnrolled.icon")

            VStack(spacing: 8) {
                Text("Not Enrolled")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("vaultHealth.notEnrolled.title")

                Text("Complete enrollment to access your secure Nitro Enclave vault.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("vaultHealth.notEnrolled.subtitle")
            }
        }
        .padding()
        .accessibilityIdentifier("vaultHealth.notEnrolledView")
    }
}

// MARK: - Error View

struct ErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)
                .accessibilityIdentifier("vaultHealth.error.icon")

            VStack(spacing: 8) {
                Text("Error")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("vaultHealth.error.title")

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("vaultHealth.error.message")
            }

            Button(action: onRetry) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .cornerRadius(12)
            }
            .accessibilityIdentifier("vaultHealth.error.retryButton")
        }
        .padding()
        .accessibilityIdentifier("vaultHealth.errorView")
    }
}

// MARK: - Vault Health Details View

struct VaultHealthDetailsView: View {
    let info: VaultHealthInfo
    let onTerminate: () -> Void

    @State private var showTerminateConfirmation = false

    var body: some View {
        VStack(spacing: 20) {
            // Status Header
            statusHeader

            // Enclave Info
            enclaveInfoSection

            // Component Status Section
            componentStatusSection

            // Stats Section
            statsSection

            // Danger Zone
            dangerZoneSection
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 20, height: 20)
                .accessibilityIdentifier("vaultHealth.details.statusIndicator")

            Text(info.status.displayName)
                .font(.title)
                .fontWeight(.bold)
                .accessibilityIdentifier("vaultHealth.details.statusText")

            Spacer()

            VStack(alignment: .trailing) {
                Text("Uptime")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(info.formattedUptime)
                    .font(.headline)
                    .accessibilityIdentifier("vaultHealth.details.uptime")
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .accessibilityIdentifier("vaultHealth.details.statusHeader")
    }

    private var enclaveInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enclave")
                .font(.headline)
                .foregroundColor(.secondary)

            HStack {
                Image(systemName: "shield.checkered")
                    .foregroundColor(.green)
                    .frame(width: 24)

                Text("Nitro Enclave")
                    .font(.subheadline)

                Spacer()

                Text("Hardware Isolated")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }

    private var componentStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Components")
                .font(.headline)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                ComponentStatusRow(
                    icon: "server.rack",
                    title: "Local NATS",
                    isActive: info.localNatsConnected,
                    detail: "\(info.localNatsConnections) connections"
                )

                ComponentStatusRow(
                    icon: "network",
                    title: "Central NATS",
                    isActive: info.centralNatsConnected,
                    detail: "\(info.centralNatsLatency)ms (\(info.latencyDescription))"
                )

                ComponentStatusRow(
                    icon: "gearshape.2.fill",
                    title: "Vault Manager",
                    isActive: info.vaultManagerRunning,
                    detail: "\(info.handlersLoaded) handlers"
                )
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resources")
                .font(.headline)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                StatCard(title: "Memory", value: "\(info.vaultManagerMemoryMb) MB", icon: "memorychip")
                StatCard(title: "CPU", value: String(format: "%.1f%%", info.vaultManagerCpuPercent), icon: "cpu")
                StatCard(title: "Handlers", value: "\(info.handlersLoaded)", icon: "square.stack.3d.up")
            }
        }
    }

    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Danger Zone")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            Button(action: { showTerminateConfirmation = true }) {
                HStack {
                    Image(systemName: "trash.fill")
                    Text("Terminate Vault")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.red)
                .cornerRadius(12)
            }
            .accessibilityIdentifier("vaultHealth.details.terminateButton")
            .alert("Terminate Vault?", isPresented: $showTerminateConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Terminate", role: .destructive, action: onTerminate)
            } message: {
                Text("This will permanently delete your vault. This action cannot be undone.")
            }

            if let lastEvent = info.lastEventAt {
                Text("Last event: \(lastEvent, style: .relative) ago")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("vaultHealth.details.lastEvent")
            }
        }
        .accessibilityIdentifier("vaultHealth.details.dangerZoneSection")
    }

    private var statusColor: Color {
        switch info.status {
        case .healthy: return .green
        case .degraded: return .yellow
        case .unhealthy: return .red
        }
    }
}

// MARK: - Component Status Row

struct ComponentStatusRow: View {
    let icon: String
    let title: String
    let isActive: Bool
    var detail: String? = nil

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(isActive ? .green : .red)
                .frame(width: 24)

            Image(systemName: isActive ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isActive ? .green : .red)

            Text(title)
                .font(.subheadline)

            Spacer()

            if let detail = detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)

            Text(value)
                .font(.headline)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Previews

#if DEBUG
struct VaultHealthView_Previews: PreviewProvider {
    static var previews: some View {
        Text("VaultHealthView Preview")
    }
}
#endif
