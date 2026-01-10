import SwiftUI

/// Main view for credential recovery via QR code scanning
/// Per Architecture v2.0 Section 5.18, this handles:
/// 1. QR code scanning from Account Portal
/// 2. Password entry for re-encryption
/// 3. Token exchange with vault
/// 4. Credential restoration
struct RecoveryScannerView: View {

    @StateObject private var viewModel: RecoveryViewModel
    @Environment(\.dismiss) private var dismiss

    init(onRecoveryComplete: ((String, String) -> Void)? = nil) {
        self._viewModel = StateObject(wrappedValue: RecoveryViewModel(onRecoveryComplete: onRecoveryComplete))
    }

    var body: some View {
        NavigationView {
            Group {
                switch viewModel.state {
                case .idle:
                    startView
                case .scanning:
                    scannerView
                case .validating:
                    validatingView
                case .enteringPassword:
                    passwordEntryView
                case .exchangingToken:
                    exchangingView
                case .savingCredential:
                    savingView
                case .completed(let userGuid):
                    completedView(userGuid: userGuid)
                case .failed(let error):
                    failedView(error: error)
                }
            }
            .navigationTitle("Account Recovery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if viewModel.state != .completed(userGuid: "") {
                        Button("Cancel") {
                            viewModel.cancelRecovery()
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Start View

    private var startView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 80))
                .foregroundColor(.blue)

            Text("Recover Your Account")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Scan the recovery QR code from the Account Portal to restore your credentials.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 16) {
                Button(action: { viewModel.startScanning() }) {
                    Label("Scan Recovery Code", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("You can find this code on the Account Portal after initiating recovery.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Scanner View

    private var scannerView: some View {
        ZStack {
            QRScannerView { code in
                viewModel.handleScannedCode(code)
            }

            ScanOverlayView()

            VStack {
                Spacer()

                Text("Position the recovery QR code within the frame")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                    .padding(.bottom, 60)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Validating View

    private var validatingView: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text("Validating recovery code...")
                .font(.headline)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    // MARK: - Password Entry View

    private var passwordEntryView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)

                Text("Set New Password")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Your recovered credential will be encrypted with this new password.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                VStack(spacing: 16) {
                    SecureField("New Password", text: $viewModel.newPassword)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.newPassword)

                    SecureField("Confirm Password", text: $viewModel.confirmPassword)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.newPassword)

                    if let error = viewModel.passwordError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal)

                VStack(spacing: 12) {
                    PasswordRequirement(
                        text: "At least 8 characters",
                        isMet: viewModel.newPassword.count >= 8
                    )
                    PasswordRequirement(
                        text: "Passwords match",
                        isMet: !viewModel.confirmPassword.isEmpty && viewModel.newPassword == viewModel.confirmPassword
                    )
                }
                .padding(.horizontal)

                Button(action: { viewModel.proceedWithRecovery() }) {
                    Text("Recover Account")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canProceedWithPassword)
                .padding(.horizontal)
                .padding(.top, 16)
            }
            .padding(.vertical, 32)
        }
    }

    // MARK: - Exchanging View

    private var exchangingView: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text("Recovering your credentials...")
                .font(.headline)

            Text("This may take a moment")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    // MARK: - Saving View

    private var savingView: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text("Saving credentials...")
                .font(.headline)

            Spacer()
        }
    }

    // MARK: - Completed View

    private func completedView(userGuid: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)

            Text("Recovery Complete!")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Your account has been successfully recovered. You can now use VettID as normal.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            Button(action: { dismiss() }) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Failed View

    private func failedView(error: RecoveryError) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("Recovery Failed")
                .font(.title2)
                .fontWeight(.semibold)

            Text(error.errorDescription ?? "An unknown error occurred")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                Button(action: { viewModel.retry() }) {
                    Text("Try Again")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: {
                    viewModel.cancelRecovery()
                    dismiss()
                }) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }
}

// MARK: - Password Requirement View

struct PasswordRequirement: View {
    let text: String
    let isMet: Bool

    var body: some View {
        HStack {
            Image(systemName: isMet ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isMet ? .green : .secondary)
            Text(text)
                .font(.caption)
                .foregroundColor(isMet ? .primary : .secondary)
            Spacer()
        }
    }
}

// MARK: - Scan Overlay (reuse from Connections)

struct RecoveryScanOverlayView: View {
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geometry in
            let scanSize = min(geometry.size.width, geometry.size.height) * 0.7

            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()

                RoundedRectangle(cornerRadius: 12)
                    .frame(width: scanSize, height: scanSize)
                    .blendMode(.destinationOut)

                // Scan corners
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.blue, lineWidth: 3)
                    .frame(width: scanSize, height: scanSize)

                // Animated scan line
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .blue.opacity(0.5), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: scanSize - 20, height: 4)
                    .offset(y: isAnimating ? scanSize / 2 - 20 : -scanSize / 2 + 20)
                    .animation(
                        .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                        value: isAnimating
                    )
            }
            .compositingGroup()
            .onAppear {
                isAnimating = true
            }
        }
    }
}

#if DEBUG
struct RecoveryScannerView_Previews: PreviewProvider {
    static var previews: some View {
        RecoveryScannerView()
    }
}
#endif
