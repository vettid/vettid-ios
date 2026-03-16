import SwiftUI

/// View for creating a device pairing invitation code
struct DevicePairingView: View {
    @StateObject private var viewModel: DevicePairingViewModel
    @Environment(\.dismiss) private var dismiss

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self._viewModel = StateObject(wrappedValue: DevicePairingViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        VStack(spacing: 24) {
            switch viewModel.state {
            case .idle:
                idleView

            case .creating:
                loadingView(message: "Creating invitation...")

            case .showingCode(let inviteCode, _):
                codeView(inviteCode: inviteCode)

            case .waitingApproval:
                waitingApprovalView

            case .approved:
                resultView(
                    icon: "checkmark.circle.fill",
                    iconColor: .green,
                    title: "Device Paired",
                    message: "The new device has been successfully paired with your vault."
                )

            case .denied:
                resultView(
                    icon: "xmark.circle.fill",
                    iconColor: .red,
                    title: "Pairing Denied",
                    message: "The device pairing request was denied."
                )

            case .timeout:
                resultView(
                    icon: "clock.badge.exclamationmark.fill",
                    iconColor: .orange,
                    title: "Code Expired",
                    message: "The pairing code has expired. Create a new one to try again."
                )

            case .error(let message):
                resultView(
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .red,
                    title: "Pairing Failed",
                    message: message
                )
            }
        }
        .padding()
        .navigationTitle("Pair Device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    viewModel.cancel()
                    dismiss()
                }
            }
        }
    }

    // MARK: - Idle View

    private var idleView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "link.badge.plus")
                .font(.system(size: 80))
                .foregroundStyle(.blue)

            VStack(spacing: 12) {
                Text("Pair a New Device")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Generate a pairing code to connect another device to your vault. The code will be valid for 5 minutes.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                Task {
                    await viewModel.createInvitation()
                }
            } label: {
                Text("Generate Pairing Code")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
    }

    // MARK: - Loading View

    private func loadingView(message: String) -> some View {
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

    // MARK: - Code View

    private func codeView(inviteCode: String) -> some View {
        VStack(spacing: 32) {
            // Countdown timer
            countdownBadge

            Spacer()

            VStack(spacing: 20) {
                Text("Your Pairing Code")
                    .font(.title2)
                    .fontWeight(.semibold)

                // Code display
                Text(inviteCode)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .tracking(4)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )

                Text("Enter this code on the device you want to pair")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
                // Copy button
                Button {
                    UIPasteboard.general.string = inviteCode
                } label: {
                    Label("Copy Code", systemImage: "doc.on.doc")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                // Cancel button
                Button {
                    viewModel.cancel()
                } label: {
                    Text("Cancel")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray.opacity(0.15))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }
            }
        }
    }

    // MARK: - Countdown Badge

    private var countdownBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.fill")
                .foregroundStyle(viewModel.isCountdownWarning ? .orange : .secondary)

            Text("Expires in \(viewModel.formattedCountdown)")
                .font(.subheadline)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(viewModel.isCountdownWarning ? .orange : .secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(viewModel.isCountdownWarning ? Color.orange.opacity(0.1) : Color.gray.opacity(0.1))
        )
    }

    // MARK: - Waiting Approval View

    private var waitingApprovalView: some View {
        VStack(spacing: 32) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            VStack(spacing: 12) {
                Text("Waiting for Approval")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("The pairing request has been submitted. Waiting for approval from the vault.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                viewModel.cancel()
            } label: {
                Text("Cancel")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.15))
                    .foregroundColor(.primary)
                    .cornerRadius(12)
            }
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

            VStack(spacing: 12) {
                if viewModel.state == .timeout || viewModel.state != .approved {
                    Button {
                        viewModel.reset()
                    } label: {
                        Text("Try Again")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }

                Button {
                    dismiss()
                } label: {
                    Text(viewModel.state == .approved ? "Done" : "Close")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(viewModel.state == .approved ? Color.blue : Color.gray.opacity(0.15))
                        .foregroundColor(viewModel.state == .approved ? .white : .primary)
                        .cornerRadius(12)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        DevicePairingView()
    }
}
