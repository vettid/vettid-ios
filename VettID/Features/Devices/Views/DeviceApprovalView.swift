import SwiftUI

/// View for approving or denying a device connection request
struct DeviceApprovalView: View {
    @StateObject private var viewModel: DeviceApprovalViewModel
    @Environment(\.dismiss) private var dismiss

    let approvalRequest: DeviceApprovalRequest?

    init(
        ownerSpaceClient: OwnerSpaceClient? = nil,
        approvalRequest: DeviceApprovalRequest? = nil
    ) {
        self.approvalRequest = approvalRequest
        self._viewModel = StateObject(wrappedValue: DeviceApprovalViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch viewModel.state {
                case .loading:
                    loadingView

                case .ready(let info):
                    approvalView(info: info)

                case .processingApproval:
                    processingView(message: "Approving device...")

                case .processingDenial:
                    processingView(message: "Denying request...")

                case .approved:
                    resultView(
                        icon: "checkmark.circle.fill",
                        iconColor: .green,
                        title: "Device Approved",
                        message: "The device has been approved and can now connect to your vault."
                    )

                case .denied:
                    resultView(
                        icon: "hand.raised.fill",
                        iconColor: .orange,
                        title: "Device Denied",
                        message: "The device connection request has been denied."
                    )

                case .timeout:
                    resultView(
                        icon: "clock.badge.exclamationmark.fill",
                        iconColor: .orange,
                        title: "Request Timed Out",
                        message: "The approval request has timed out. The requesting device will need to try again."
                    )

                case .error(let message):
                    resultView(
                        icon: "exclamationmark.triangle.fill",
                        iconColor: .red,
                        title: "Error",
                        message: message
                    )
                }
            }
            .padding()
            .navigationTitle("Device Approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let request = approvalRequest {
                    viewModel.setApprovalRequest(request)
                } else {
                    viewModel.loadPendingApproval()
                }
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            VStack(spacing: 8) {
                Text("Waiting for Request")
                    .font(.headline)

                Text("Listening for device approval requests...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Approval View

    private func approvalView(info: DeviceApprovalInfo) -> some View {
        VStack(spacing: 24) {
            // Elapsed time badge
            elapsedTimeBadge

            // Device info header
            VStack(spacing: 16) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Device Connection Request")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("A new device is requesting to connect to your vault.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Device details card
            VStack(alignment: .leading, spacing: 12) {
                detailRow(icon: "desktopcomputer", label: "Device Name", value: info.deviceName)

                if let operation = info.operation {
                    detailRow(icon: "gearshape", label: "Operation", value: operation)
                }

                if let category = info.secretCategory {
                    detailRow(icon: "lock.shield", label: "Access", value: category)
                }

                detailRow(
                    icon: "network",
                    label: "Connection ID",
                    value: String(info.connectionId.prefix(12)) + "..."
                )

                if let timestamp = info.timestamp {
                    detailRow(
                        icon: "calendar",
                        label: "Requested",
                        value: formatDate(timestamp)
                    )
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
            )

            Spacer()

            // Security warning
            securityWarning

            // Action buttons
            actionButtons(requestId: info.requestId)
        }
    }

    // MARK: - Elapsed Time Badge

    private var elapsedTimeBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.fill")
                .foregroundStyle(viewModel.isNearingTimeout ? .orange : .secondary)

            Text("Elapsed: \(viewModel.formattedElapsedTime)")
                .font(.subheadline)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(viewModel.isNearingTimeout ? .orange : .secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(viewModel.isNearingTimeout ? Color.orange.opacity(0.1) : Color.gray.opacity(0.1))
        )
    }

    // MARK: - Detail Row

    private func detailRow(icon: String, label: String, value: String) -> some View {
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

    // MARK: - Security Warning

    private var securityWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text("Only approve if you initiated this connection. Do not approve unexpected requests.")
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

    private func actionButtons(requestId: String) -> some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    await viewModel.approve(requestId: requestId)
                }
            } label: {
                HStack {
                    Image(systemName: "checkmark.shield.fill")
                    Text("Approve Device")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
            }

            Button {
                Task {
                    await viewModel.deny(requestId: requestId)
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
        }
    }

    // MARK: - Processing View

    private func processingView(message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    // MARK: - Result View

    private func resultView(icon: String, iconColor: Color, title: String, message: String) -> some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 80))
                .foregroundStyle(iconColor)

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

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#Preview {
    DeviceApprovalView()
}
