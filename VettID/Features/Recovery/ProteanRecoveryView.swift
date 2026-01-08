import SwiftUI

// MARK: - Protean Recovery View

/// Main view for credential recovery with 24-hour delay
struct ProteanRecoveryView: View {
    @StateObject private var service: ProteanRecoveryService
    @Environment(\.dismiss) private var dismiss

    init(authTokenProvider: @escaping @Sendable () -> String?) {
        _service = StateObject(wrappedValue: ProteanRecoveryService(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch service.state {
                case .idle:
                    RecoveryRequestView(onRequest: requestRecovery)

                case .requesting:
                    ProgressView("Requesting recovery...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .pending:
                    if let recovery = service.activeRecovery {
                        RecoveryPendingView(
                            recovery: recovery,
                            remainingTime: service.remainingTimeString,
                            onCancel: cancelRecovery,
                            onRefresh: refreshStatus
                        )
                    }

                case .ready:
                    RecoveryReadyView(onDownload: { password in
                        confirmAndAuthenticate(password: password)
                    })

                case .downloading:
                    ProgressView("Preparing restore...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .authenticating:
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Authenticating with vault...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .complete:
                    ProteanRecoveryCompleteView(onDone: { dismiss() })

                case .cancelling:
                    ProgressView("Cancelling recovery...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .cancelled:
                    RecoveryCancelledView(onDismiss: { dismiss() })

                case .expired:
                    RecoveryExpiredView(onRetry: requestRecovery, onDismiss: { dismiss() })

                case .error:
                    ProteanRecoveryErrorView(
                        error: service.error,
                        onRetry: retryAction,
                        onDismiss: { dismiss() }
                    )
                }
            }
            .navigationTitle("Credential Recovery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if service.state == .idle || service.state == .error {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .task {
            await service.checkForPendingRecovery()
        }
    }

    // MARK: - Actions

    private func requestRecovery() {
        Task {
            await service.requestRecovery()
        }
    }

    private func cancelRecovery() {
        Task {
            await service.cancelRecovery()
        }
    }

    private func refreshStatus() {
        Task {
            await service.checkStatus()
        }
    }

    private func confirmAndAuthenticate(password: String) {
        Task {
            await service.confirmAndAuthenticate(password: password)
        }
    }

    private func retryAction() {
        service.reset()
    }
}

// MARK: - Recovery Request View

private struct RecoveryRequestView: View {
    let onRequest: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 60))
                    .foregroundStyle(.orange)
                    .padding(.top, 40)

                Text("Recover Your Credential")
                    .font(.title2)
                    .fontWeight(.semibold)

                VStack(alignment: .leading, spacing: 16) {
                    SecurityFeatureRow(
                        icon: "lock.shield",
                        title: "24-Hour Security Delay",
                        description: "For your protection, credential recovery requires a 24-hour waiting period."
                    )

                    SecurityFeatureRow(
                        icon: "bell.badge",
                        title: "Notification When Ready",
                        description: "You'll receive a notification when your credential is ready to download."
                    )

                    SecurityFeatureRow(
                        icon: "xmark.circle",
                        title: "Cancel Anytime",
                        description: "If you didn't request this recovery, you can cancel it at any time during the waiting period."
                    )

                    SecurityFeatureRow(
                        icon: "exclamationmark.triangle",
                        title: "Why the Delay?",
                        description: "This delay prevents unauthorized access if someone gains temporary access to your account."
                    )
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                Spacer()

                Button(action: onRequest) {
                    Text("Request Recovery")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - Recovery Pending View

private struct RecoveryPendingView: View {
    let recovery: ActiveRecoveryInfo
    let remainingTime: String
    let onCancel: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Progress ring
                ZStack {
                    Circle()
                        .stroke(Color(.systemGray4), lineWidth: 8)

                    Circle()
                        .trim(from: 0, to: recovery.progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut, value: recovery.progress)

                    VStack(spacing: 4) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)

                        Text(remainingTime)
                            .font(.headline)
                            .monospacedDigit()
                    }
                }
                .frame(width: 150, height: 150)
                .padding(.top, 40)

                Text("Recovery in Progress")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Your credential will be available for download after the 24-hour security delay.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 12) {
                    ProteanInfoRow(label: "Request ID", value: String(recovery.recoveryId.prefix(8)) + "...")
                    ProteanInfoRow(label: "Requested", value: formatDate(recovery.requestedAt))
                    ProteanInfoRow(label: "Available at", value: formatDate(recovery.availableAt))
                    ProteanInfoRow(label: "Status", value: recovery.status.rawValue.capitalized)
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                Spacer()

                VStack(spacing: 12) {
                    Button(action: onRefresh) {
                        Label("Refresh Status", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button(action: onCancel) {
                        Text("Cancel Recovery")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Recovery Ready View

private struct RecoveryReadyView: View {
    let onDownload: (String) -> Void
    @State private var password = ""
    @State private var isPasswordVisible = false
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
                .padding(.top, 40)

            Text("Recovery Ready!")
                .font(.title)
                .fontWeight(.bold)

            Text("Enter your vault password to complete the recovery and restore access to your VettID.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            // Password field
            VStack(alignment: .leading, spacing: 8) {
                Text("Vault Password")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    Group {
                        if isPasswordVisible {
                            TextField("Enter password", text: $password)
                        } else {
                            SecureField("Enter password", text: $password)
                        }
                    }
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isPasswordFocused)

                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal)

            Spacer()

            Button {
                onDownload(password)
            } label: {
                Text("Restore Credential")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(password.isEmpty ? Color.gray : Color.green)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(password.isEmpty)
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        .onAppear {
            isPasswordFocused = true
        }
    }
}

// MARK: - Recovery Complete View

private struct ProteanRecoveryCompleteView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 80))
                .foregroundStyle(.orange)
                .padding(.top, 60)

            Text("Recovery Complete!")
                .font(.title)
                .fontWeight(.bold)

            Text("Your credential has been restored. You can now use VettID normally.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Spacer()

            Button(action: onDone) {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Recovery Cancelled View

private struct RecoveryCancelledView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
                .padding(.top, 60)

            Text("Recovery Cancelled")
                .font(.title)
                .fontWeight(.bold)

            Text("Your recovery request has been cancelled. You can start a new recovery at any time.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Spacer()

            Button(action: onDismiss) {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Recovery Expired View

private struct RecoveryExpiredView: View {
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 80))
                .foregroundStyle(.orange)
                .padding(.top, 60)

            Text("Recovery Expired")
                .font(.title)
                .fontWeight(.bold)

            Text("Your recovery request has expired. Please start a new recovery request.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                Button(action: onRetry) {
                    Text("Request New Recovery")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button(action: onDismiss) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Recovery Error View

private struct ProteanRecoveryErrorView: View {
    let error: ProteanRecoveryError?
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.red)
                .padding(.top, 60)

            Text("Recovery Error")
                .font(.title)
                .fontWeight(.bold)

            Text(error?.localizedDescription ?? "An unknown error occurred.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                Button(action: onRetry) {
                    Text("Try Again")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button(action: onDismiss) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Helper Views

private struct SecurityFeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 24)

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

private struct ProteanInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }
}

// MARK: - Preview

#Preview {
    ProteanRecoveryView(authTokenProvider: { "mock-token" })
}
