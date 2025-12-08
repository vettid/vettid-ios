import SwiftUI

/// Main vault health display view
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
            .navigationTitle("Vault Health")
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

        case .notProvisioned:
            NotProvisionedView(onProvision: {
                Task { await viewModel.provisionVault() }
            })

        case .provisioning(let progress, let status):
            ProvisioningView(progress: progress, status: status)

        case .stopped:
            StoppedVaultView(onStart: {
                Task { await viewModel.provisionVault() }
            })

        case .loaded(let info):
            VaultHealthDetailsView(
                info: info,
                onStop: {
                    Task { await viewModel.stopVault() }
                },
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
            Text("Checking vault status...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 80)
    }
}

// MARK: - Not Provisioned View

struct NotProvisionedView: View {
    let onProvision: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "server.rack")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                Text("No Vault Instance")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("You don't have a vault provisioned yet. Your vault securely stores and processes your data.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: onProvision) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Provision Vault")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .cornerRadius(12)
            }
        }
        .padding()
    }
}

// MARK: - Provisioning View

struct ProvisioningView: View {
    let progress: Double
    let status: String

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 8)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)

                VStack(spacing: 4) {
                    Text("\(Int(progress * 100))%")
                        .font(.title2)
                        .fontWeight(.bold)
                    Image(systemName: "server.rack")
                        .foregroundColor(.blue)
                }
            }

            VStack(spacing: 8) {
                Text("Provisioning Vault")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(status)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Text("This may take 1-2 minutes")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

// MARK: - Stopped Vault View

struct StoppedVaultView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            VStack(spacing: 8) {
                Text("Vault Stopped")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Your vault instance is stopped. Start it to access your data.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: onStart) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Start Vault")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .cornerRadius(12)
            }
        }
        .padding()
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

            VStack(spacing: 8) {
                Text("Error")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
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
        }
        .padding()
    }
}

// MARK: - Vault Health Details View

struct VaultHealthDetailsView: View {
    let info: VaultHealthInfo
    let onStop: () -> Void
    let onTerminate: () -> Void

    @State private var showTerminateConfirmation = false

    var body: some View {
        VStack(spacing: 20) {
            // Status Header
            statusHeader

            // Component Status Section
            componentStatusSection

            // Stats Section
            statsSection

            // Actions Section
            actionsSection
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 20, height: 20)

            Text(info.status.displayName)
                .font(.title)
                .fontWeight(.bold)

            Spacer()

            VStack(alignment: .trailing) {
                Text("Uptime")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(info.formattedUptime)
                    .font(.headline)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
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

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actions")
                .font(.headline)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button(action: onStop) {
                    HStack {
                        Image(systemName: "pause.fill")
                        Text("Stop")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .cornerRadius(12)
                }

                Button(action: { showTerminateConfirmation = true }) {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("Terminate")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .cornerRadius(12)
                }
            }
            .alert("Terminate Vault?", isPresented: $showTerminateConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Terminate", role: .destructive, action: onTerminate)
            } message: {
                Text("This will permanently delete your vault instance. This action cannot be undone.")
            }

            if let lastEvent = info.lastEventAt {
                Text("Last event: \(lastEvent, style: .relative) ago")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
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
        // Preview with mock data would go here
        Text("VaultHealthView Preview")
    }
}
#endif
