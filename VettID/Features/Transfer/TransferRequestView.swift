import SwiftUI

/// View for requesting a credential transfer from another device (new device flow)
struct TransferRequestView: View {
    @StateObject private var viewModel = TransferViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch viewModel.state {
                case .idle:
                    idleView

                case .requesting:
                    loadingView(message: "Requesting transfer...")

                case .waitingForApproval(_, let expiresAt):
                    waitingView(expiresAt: expiresAt)

                case .approved:
                    successView(title: "Transfer Approved", message: "Receiving credential...")

                case .completed:
                    successView(title: "Transfer Complete", message: "Your credential has been transferred successfully.")

                case .denied:
                    errorView(title: "Transfer Denied", message: "The transfer request was denied by the other device.")

                case .expired:
                    errorView(title: "Request Expired", message: "The transfer request has expired. Please try again.")

                case .error(let message):
                    errorView(title: "Transfer Failed", message: message)

                case .pendingApproval:
                    // This state is for old device flow, shouldn't appear here
                    EmptyView()
                }
            }
            .padding()
            .navigationTitle("Transfer Credential")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task {
                            await viewModel.cancelRequest()
                        }
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Idle State

    private var idleView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue)

            VStack(spacing: 12) {
                Text("Transfer from Another Device")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Request to transfer your credential from a device where you're already signed in.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 16) {
                Button {
                    Task {
                        await viewModel.requestTransfer()
                    }
                } label: {
                    Text("Request Transfer")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                Text("A notification will be sent to your other device for approval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Loading State

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

    // MARK: - Waiting State

    private func waitingView(expiresAt: Date) -> some View {
        VStack(spacing: 32) {
            Spacer()

            // Animated waiting indicator
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: CGFloat(viewModel.timeRemaining / TransferTimeout.requestExpiration))
                    .stroke(
                        viewModel.isTimeWarning ? Color.orange : Color.blue,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: viewModel.timeRemaining)

                VStack(spacing: 4) {
                    Text(viewModel.formattedTimeRemaining)
                        .font(.title)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundStyle(viewModel.isTimeWarning ? .orange : .primary)

                    Text("remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 12) {
                Text("Waiting for Approval")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Open VettID on your other device and approve the transfer request.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                Task {
                    await viewModel.cancelRequest()
                }
            } label: {
                Text("Cancel Request")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.primary)
                    .cornerRadius(12)
            }
        }
    }

    // MARK: - Success State

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

            if case .completed = viewModel.state {
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
            } else {
                ProgressView()
                    .padding()
            }
        }
    }

    // MARK: - Error State

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

            VStack(spacing: 12) {
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

                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    TransferRequestView()
}
