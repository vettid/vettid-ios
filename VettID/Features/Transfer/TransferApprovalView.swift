import SwiftUI

/// View for approving or denying a credential transfer request (old device flow)
struct TransferApprovalView: View {
    @StateObject private var viewModel = TransferViewModel()
    @Environment(\.dismiss) private var dismiss

    let transferRequest: TransferRequestedEvent

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch viewModel.state {
                case .pendingApproval:
                    approvalView

                case .approved:
                    successView(
                        title: "Transfer Approved",
                        message: "The credential is being transferred to the new device."
                    )

                case .denied:
                    successView(
                        title: "Transfer Denied",
                        message: "The transfer request has been denied."
                    )

                case .expired:
                    errorView(
                        title: "Request Expired",
                        message: "The transfer request has expired."
                    )

                case .error(let message):
                    errorView(title: "Error", message: message)

                default:
                    loadingView
                }
            }
            .padding()
            .navigationTitle("Transfer Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                viewModel.handleTransferRequest(transferRequest)
            }
        }
    }

    // MARK: - Approval View

    private var approvalView: some View {
        VStack(spacing: 24) {
            // Timer
            timerSection

            // Device Info
            deviceInfoSection

            Spacer()

            // Warning
            warningSection

            // Action Buttons
            actionButtons
        }
    }

    // MARK: - Timer Section

    private var timerSection: some View {
        HStack {
            Image(systemName: "clock.fill")
                .foregroundStyle(viewModel.isTimeWarning ? .orange : .secondary)

            Text("Expires in \(viewModel.formattedTimeRemaining)")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(viewModel.isTimeWarning ? .orange : .secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(viewModel.isTimeWarning ? Color.orange.opacity(0.1) : Color.gray.opacity(0.1))
        )
    }

    // MARK: - Device Info Section

    private var deviceInfoSection: some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Transfer Request")
                .font(.title2)
                .fontWeight(.semibold)

            Text("A new device is requesting to receive your credential.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Device Details Card
            VStack(alignment: .leading, spacing: 12) {
                deviceInfoRow(icon: "iphone", label: "Device", value: transferRequest.targetDeviceInfo.model)

                deviceInfoRow(icon: "gear", label: "OS Version", value: transferRequest.targetDeviceInfo.osVersion)

                if let location = transferRequest.targetDeviceInfo.location {
                    deviceInfoRow(icon: "location.fill", label: "Location", value: location)
                }

                if let appVersion = transferRequest.targetDeviceInfo.appVersion {
                    deviceInfoRow(icon: "app.badge", label: "App Version", value: appVersion)
                }

                deviceInfoRow(
                    icon: "calendar",
                    label: "Requested",
                    value: formatDate(transferRequest.requestedAt)
                )
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
            )
        }
    }

    private func deviceInfoRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.secondary)

            Text(label)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Warning Section

    private var warningSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text("Only approve if you requested this transfer. Do not approve unexpected requests.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    await viewModel.approve()
                }
            } label: {
                HStack {
                    Image(systemName: "faceid")
                    Text("Approve with Face ID")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(viewModel.isLoading)

            Button {
                Task {
                    await viewModel.deny()
                }
            } label: {
                Text("Deny Request")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .foregroundColor(.red)
                    .cornerRadius(12)
            }
            .disabled(viewModel.isLoading)
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Processing...")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Success View

    private func successView(title: String, message: String) -> some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)

            VStack(spacing: 12) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
    }

    // MARK: - Error View

    private func errorView(title: String, message: String) -> some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.red)

            VStack(spacing: 12) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Close")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    TransferApprovalView(
        transferRequest: TransferRequestedEvent(
            transferId: "test-123",
            sourceDeviceId: "device-456",
            targetDeviceInfo: DeviceInfo(
                deviceId: "new-device-789",
                model: "iPhone 15 Pro",
                osVersion: "iOS 17.2",
                appVersion: "1.0.0",
                location: "San Francisco, CA"
            ),
            requestedAt: Date(),
            expiresAt: Date().addingTimeInterval(900)
        )
    )
}
