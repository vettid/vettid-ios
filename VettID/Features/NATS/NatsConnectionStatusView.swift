import SwiftUI

/// Compact connection status indicator for use in headers/toolbars
struct NatsConnectionStatusView: View {
    @ObservedObject var viewModel: NatsSetupViewModel

    var body: some View {
        HStack(spacing: 6) {
            statusIndicator
            statusText
        }
        .font(.caption)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch viewModel.setupState {
        case .connected:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)

        case .checkingStatus, .creatingAccount, .generatingToken, .connecting:
            ProgressView()
                .scaleEffect(0.6)

        case .error:
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)

        case .initial:
            Circle()
                .fill(.gray)
                .frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch viewModel.setupState {
        case .connected:
            Text("Connected")
                .foregroundStyle(.green)

        case .checkingStatus:
            Text("Checking...")
                .foregroundStyle(.secondary)

        case .creatingAccount:
            Text("Creating...")
                .foregroundStyle(.secondary)

        case .generatingToken:
            Text("Authenticating...")
                .foregroundStyle(.secondary)

        case .connecting:
            Text("Connecting...")
                .foregroundStyle(.secondary)

        case .error(let message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(1)

        case .initial:
            Text("Not connected")
                .foregroundStyle(.secondary)
        }
    }
}

/// Full NATS setup view with details
struct NatsSetupView: View {
    @StateObject private var viewModel = NatsSetupViewModel()
    @Environment(\.dismiss) private var dismiss

    let authToken: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch viewModel.setupState {
                case .initial:
                    initialView

                case .checkingStatus, .creatingAccount, .generatingToken, .connecting:
                    progressView

                case .connected(let status):
                    connectedView(status: status)

                case .error(let message):
                    errorView(message: message)
                }
            }
            .padding()
            .navigationTitle("NATS Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            Task {
                await viewModel.setupNats(authToken: authToken)
            }
        }
    }

    // MARK: - Initial View

    private var initialView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Connect to NATS")
                .font(.title2)
                .fontWeight(.bold)

            Text("Set up real-time communication with your vault")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Connect") {
                Task {
                    await viewModel.setupNats(authToken: authToken)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
    }

    // MARK: - Progress View

    private var progressView: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text(viewModel.setupState.title)
                .font(.headline)

            Text(progressDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Progress steps
            VStack(alignment: .leading, spacing: 12) {
                stepRow(title: "Check Status", completed: stepCompleted(for: .checkingStatus))
                stepRow(title: "Create Account", completed: stepCompleted(for: .creatingAccount))
                stepRow(title: "Generate Token", completed: stepCompleted(for: .generatingToken))
                stepRow(title: "Connect", completed: stepCompleted(for: .connecting))
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            Spacer()
        }
    }

    private var progressDescription: String {
        switch viewModel.setupState {
        case .checkingStatus:
            return "Checking your NATS account status..."
        case .creatingAccount:
            return "Creating your NATS account..."
        case .generatingToken:
            return "Generating authentication token..."
        case .connecting:
            return "Establishing secure connection..."
        default:
            return ""
        }
    }

    private func stepCompleted(for step: NatsSetupViewModel.SetupState) -> Bool? {
        let steps: [NatsSetupViewModel.SetupState] = [
            .checkingStatus, .creatingAccount, .generatingToken, .connecting
        ]

        guard let currentIndex = steps.firstIndex(of: viewModel.setupState),
              let stepIndex = steps.firstIndex(of: step) else {
            if case .connected = viewModel.setupState {
                return true
            }
            return nil
        }

        if stepIndex < currentIndex {
            return true
        } else if stepIndex == currentIndex {
            return nil // In progress
        } else {
            return false
        }
    }

    private func stepRow(title: String, completed: Bool?) -> some View {
        HStack {
            if let completed = completed {
                Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(completed ? .green : .gray)
            } else {
                ProgressView()
                    .scaleEffect(0.8)
            }

            Text(title)
                .foregroundStyle(completed == nil ? .primary : .secondary)
        }
    }

    // MARK: - Connected View

    private func connectedView(status: NatsAccountStatus) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Connected!")
                .font(.title2)
                .fontWeight(.bold)

            Text("Your vault connection is active")
                .font(.body)
                .foregroundStyle(.secondary)

            // Connection details
            VStack(spacing: 12) {
                detailRow(label: "Owner Space", value: status.ownerSpaceShortId)
                detailRow(label: "Status", value: "Active")
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            Spacer()

            Button("Disconnect") {
                Task {
                    await viewModel.disconnect()
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            Text("Connection Failed")
                .font(.title2)
                .fontWeight(.bold)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                Task {
                    await viewModel.retry(authToken: authToken)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
    }
}

/// NATS status card for dashboard/home screen
struct NatsStatusCard: View {
    @ObservedObject var viewModel: NatsSetupViewModel
    @State private var showSetupSheet = false

    let authToken: String

    var body: some View {
        Button(action: {
            showSetupSheet = true
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.blue)
                        Text("NATS Connection")
                            .font(.headline)
                    }

                    NatsConnectionStatusView(viewModel: viewModel)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSetupSheet) {
            NatsSetupView(authToken: authToken)
        }
    }
}

// MARK: - Preview

#Preview("Connection Status") {
    NatsConnectionStatusView(viewModel: NatsSetupViewModel())
}

#Preview("Setup View") {
    NatsSetupView(authToken: "test-token")
}
