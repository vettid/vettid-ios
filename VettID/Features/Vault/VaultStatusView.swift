import SwiftUI

/// Main vault status view showing current status and actions
struct VaultStatusView: View {
    @StateObject private var viewModel = VaultStatusViewModel()
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    switch viewModel.state {
                    case .loading:
                        loadingView

                    case .notEnrolled:
                        notEnrolledView

                    case .enrolled(let statusInfo):
                        enrolledView(status: statusInfo)

                    case .error(let message, let retryable):
                        errorView(message: message, retryable: retryable)
                    }
                }
                .padding()
            }
            .navigationTitle("My Vault")
            .refreshable {
                await viewModel.refreshStatus()
            }
            .onAppear {
                viewModel.loadInitialState()
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Loading vault status...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: - Not Enrolled View

    private var notEnrolledView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "building.columns")
                .font(.system(size: 80))
                .foregroundStyle(.blue.opacity(0.7))

            VStack(spacing: 12) {
                Text("Set Up Your Vault")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Your personal vault provides secure storage for your credentials and secrets.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            NavigationLink(destination: EnrollmentContainerView()) {
                Label("Begin Setup", systemImage: "qrcode.viewfinder")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: - Enrolled View

    private func enrolledView(status: VaultStatusViewModel.VaultStatusInfo) -> some View {
        VStack(spacing: 24) {
            // Status Card
            statusCard(status: status)

            // Quick Stats
            quickStatsSection

            // Health Section
            if status.health != .unknown {
                healthSection(health: status.health)
            }

            // Actions
            actionsSection(status: status)

            // Info Section
            infoSection
        }
    }

    // MARK: - Status Card

    private func statusCard(status: VaultStatusViewModel.VaultStatusInfo) -> some View {
        VStack(spacing: 16) {
            // Status icon and text
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(status.status.statusColor.opacity(0.15))
                        .frame(width: 60, height: 60)

                    Image(systemName: status.status.systemImage)
                        .font(.system(size: 28))
                        .foregroundStyle(status.status.statusColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Vault Status")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(status.status.displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                }

                Spacer()
            }

            // Status-specific message
            statusMessage(status: status.status)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
    }

    private func statusMessage(status: VaultLifecycleStatus) -> some View {
        HStack {
            Image(systemName: statusMessageIcon(status))
                .foregroundStyle(statusMessageColor(status))

            Text(statusMessageText(status))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .background(statusMessageColor(status).opacity(0.1))
        .cornerRadius(8)
    }

    private func statusMessageIcon(_ status: VaultLifecycleStatus) -> String {
        switch status {
        case .running:
            return "checkmark.circle"
        case .provisioning:
            return "arrow.clockwise"
        case .stopped:
            return "info.circle"
        case .enrolled:
            return "arrow.right.circle"
        default:
            return "info.circle"
        }
    }

    private func statusMessageColor(_ status: VaultLifecycleStatus) -> Color {
        switch status {
        case .running:
            return .green
        case .provisioning:
            return .blue
        case .stopped:
            return .orange
        default:
            return .gray
        }
    }

    private func statusMessageText(_ status: VaultLifecycleStatus) -> String {
        switch status {
        case .running:
            return "Your vault is running and ready to use"
        case .provisioning:
            return "Your vault is starting up..."
        case .stopped:
            return "Start your vault to access your secrets"
        case .enrolled:
            return "Tap Start Vault to provision your instance"
        case .pendingEnrollment:
            return "Complete enrollment to use your vault"
        case .terminated:
            return "This vault has been terminated"
        }
    }

    // MARK: - Quick Stats

    private var quickStatsSection: some View {
        HStack(spacing: 16) {
            // Keys remaining
            statCard(
                title: "Keys Available",
                value: "\(viewModel.unusedKeyCount)",
                icon: "key.fill",
                color: viewModel.unusedKeyCount < 5 ? .orange : .green
            )

            // Last sync
            statCard(
                title: "Last Sync",
                value: viewModel.lastSyncAt.map { formatDate($0) } ?? "Never",
                icon: "arrow.triangle.2.circlepath",
                color: .blue
            )
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Health Section

    private func healthSection(health: VaultHealthStatus) -> some View {
        HStack {
            Image(systemName: health.systemImage)
                .foregroundStyle(health.color)

            Text("Health: \(health.displayName)")
                .font(.subheadline)
                .fontWeight(.medium)

            Spacer()

            if health == .warning {
                Text("Low keys")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(health.color.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Actions Section

    private func actionsSection(status: VaultStatusViewModel.VaultStatusInfo) -> some View {
        VStack(spacing: 12) {
            if status.status.canStart {
                Button(action: {
                    Task {
                        await viewModel.startVault(authToken: "")
                    }
                }) {
                    Label("Start Vault", systemImage: "play.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }

            if status.status.canStop {
                Button(action: {
                    Task {
                        await viewModel.stopVault(authToken: "")
                    }
                }) {
                    Label("Stop Vault", systemImage: "stop.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }

            Button(action: {
                Task {
                    await viewModel.syncVault(authToken: "")
                }
            }) {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .cornerRadius(12)
            }
        }
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vault Information")
                .font(.headline)

            if let info = viewModel.vaultInfo {
                VStack(spacing: 12) {
                    infoRow(label: "User ID", value: String(info.userGuid.prefix(8)) + "...")

                    if let enrolledAt = info.enrolledAt {
                        infoRow(label: "Enrolled", value: formatDate(enrolledAt))
                    }

                    if let lastBackup = info.lastBackup {
                        infoRow(label: "Last Backup", value: formatDate(lastBackup))
                    }

                    if let instanceId = info.instanceId {
                        infoRow(label: "Instance", value: instanceId)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
        }
    }

    // MARK: - Error View

    private func errorView(message: String, retryable: Bool) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            Text("Unable to Load Vault")
                .font(.title2)
                .fontWeight(.bold)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if retryable {
                Button("Try Again") {
                    viewModel.loadInitialState()
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Vault Status Card (for use in other views)

struct VaultStatusCard: View {
    @StateObject private var viewModel = VaultStatusViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "building.columns.fill")
                    .foregroundStyle(.blue)
                Text("Vault Status")
                    .font(.headline)
                Spacer()
                NavigationLink(destination: VaultStatusView()) {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }

            switch viewModel.state {
            case .loading:
                HStack {
                    ProgressView()
                    Text("Loading...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            case .notEnrolled:
                HStack {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Not enrolled")
                        .font(.subheadline)
                    Spacer()
                    Text("Set up")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }

            case .enrolled(let status):
                HStack {
                    Image(systemName: status.status.systemImage)
                        .foregroundStyle(status.status.statusColor)
                    Text(status.status.displayName)
                        .font(.subheadline)
                    Spacer()
                    if viewModel.unusedKeyCount < 5 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

            case .error(_, _):
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Error loading status")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        .onAppear {
            viewModel.loadInitialState()
        }
    }
}

// MARK: - Preview

#Preview {
    VaultStatusView()
        .environmentObject(AppState())
}
