import SwiftUI

/// Container view that orchestrates the authentication flow
struct AuthenticationContainerView: View {
    @StateObject private var viewModel = AuthenticationViewModel()
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                switch viewModel.state {
                case .initial:
                    ActionRequestView(viewModel: viewModel)

                case .requestingToken:
                    requestingTokenView

                case .verifyingLAT:
                    LATVerificationView(viewModel: viewModel)

                case .awaitingPassword:
                    PasswordEntryView(viewModel: viewModel)

                case .authenticating:
                    authenticatingView

                case .success, .credentialRotated:
                    AuthSuccessView(viewModel: viewModel) {
                        appState.isAuthenticated = true
                        dismiss()
                    }

                case .error(let message, let retryable):
                    authErrorView(message: message, retryable: retryable)
                }
            }
            .navigationTitle(viewModel.state.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.state.canGoBack {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Requesting Token View

    private var requestingTokenView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .accessibilityIdentifier("auth.requestingToken.spinner")

            Text("Connecting to server...")
                .font(.headline)
                .accessibilityIdentifier("auth.requestingToken.title")

            Text("Requesting authentication session")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("auth.requestingToken.subtitle")
        }
        .accessibilityIdentifier("auth.requestingTokenView")
    }

    // MARK: - Authenticating View

    private var authenticatingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .accessibilityIdentifier("auth.authenticating.spinner")

            Text("Authenticating...")
                .font(.headline)
                .accessibilityIdentifier("auth.authenticating.title")

            Text("Verifying your credentials")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("auth.authenticating.subtitle")
        }
        .accessibilityIdentifier("auth.authenticatingView")
    }

    // MARK: - Error View

    private func authErrorView(message: String, retryable: Bool) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
                .accessibilityIdentifier("auth.error.icon")

            Text("Authentication Failed")
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityIdentifier("auth.error.title")

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier("auth.error.message")

            if retryable {
                Button("Try Again") {
                    viewModel.reset()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("auth.error.retryButton")
            }

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("auth.error.cancelButton")
        }
        .padding()
        .accessibilityIdentifier("auth.errorView")
    }
}

// MARK: - Action Request View

struct ActionRequestView: View {
    @ObservedObject var viewModel: AuthenticationViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Icon
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue)
                .accessibilityIdentifier("auth.actionRequest.icon")

            // Title
            VStack(spacing: 12) {
                Text("Secure Authentication")
                    .font(.title2)
                    .fontWeight(.bold)
                    .accessibilityIdentifier("auth.actionRequest.title")

                Text("VettID uses action-based authentication with mutual verification to protect against phishing.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .accessibilityIdentifier("auth.actionRequest.subtitle")
            }

            // Key info
            if viewModel.remainingKeyCount > 0 {
                HStack {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.green)
                    Text("\(viewModel.remainingKeyCount) transaction keys available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("auth.actionRequest.keysAvailable")
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("No keys available - re-enrollment required")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .accessibilityIdentifier("auth.actionRequest.noKeys")
            }

            Spacer()

            // Start button
            Button(action: {
                Task {
                    await viewModel.requestActionToken()
                }
            }) {
                Text("Begin Authentication")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(viewModel.needsReenrollment ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(viewModel.needsReenrollment)
            .padding(.horizontal)
            .padding(.bottom, 40)
            .accessibilityIdentifier("auth.actionRequest.beginButton")
        }
        .padding()
        .accessibilityIdentifier("auth.actionRequestView")
    }
}

// MARK: - LAT Verification View

struct LATVerificationView: View {
    @ObservedObject var viewModel: AuthenticationViewModel
    @State private var userConfirmedLAT = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Security icon
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(viewModel.verifyLAT() ? .green : .red)
                .accessibilityIdentifier("auth.latVerification.icon")

            // Title
            Text("Verify Server Identity")
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityIdentifier("auth.latVerification.title")

            // Explanation
            Text("Before entering your password, verify that the server's Ledger Auth Token (LAT) matches your stored token. This protects against phishing attacks.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier("auth.latVerification.explanation")

            // LAT display
            VStack(spacing: 12) {
                Text("Server LAT ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("auth.latVerification.serverLatLabel")

                Text(viewModel.serverLatId)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .accessibilityIdentifier("auth.latVerification.serverLatValue")

                // Verification status
                HStack {
                    Image(systemName: viewModel.verifyLAT() ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(viewModel.verifyLAT() ? .green : .red)

                    Text(viewModel.verifyLAT() ? "LAT Verified - Server is authentic" : "LAT MISMATCH - Possible phishing!")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(viewModel.verifyLAT() ? .green : .red)
                }
                .padding()
                .background(viewModel.verifyLAT() ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                .cornerRadius(8)
                .accessibilityIdentifier(viewModel.verifyLAT() ? "auth.latVerification.verified" : "auth.latVerification.mismatch")
            }
            .padding()

            Spacer()

            // Actions
            if viewModel.verifyLAT() {
                Button(action: {
                    viewModel.confirmLATVerification()
                }) {
                    Text("Continue to Password")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
                .accessibilityIdentifier("auth.latVerification.continueButton")
            } else {
                VStack(spacing: 12) {
                    Text("⚠️ DO NOT enter your password!")
                        .font(.headline)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("auth.latVerification.phishingWarning")

                    Button(action: {
                        viewModel.reportLATMismatch()
                    }) {
                        Text("Report Phishing Attempt")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal)
                    .accessibilityIdentifier("auth.latVerification.reportButton")
                }
            }

            Spacer()
                .frame(height: 40)
        }
        .padding()
        .accessibilityIdentifier("auth.latVerificationView")
    }
}

// MARK: - Password Entry View

struct PasswordEntryView: View {
    @ObservedObject var viewModel: AuthenticationViewModel
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            Image(systemName: "lock.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
                .accessibilityIdentifier("auth.password.icon")

            // Title
            VStack(spacing: 12) {
                Text("Enter Your Password")
                    .font(.title2)
                    .fontWeight(.bold)
                    .accessibilityIdentifier("auth.password.title")

                Text("Server verified. Enter your vault password to authenticate.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("auth.password.subtitle")
            }

            // Password field
            VStack(alignment: .leading, spacing: 8) {
                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
                    .focused($isPasswordFocused)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    .accessibilityIdentifier("auth.password.textField")
            }
            .padding(.horizontal)

            Spacer()

            // Submit button
            Button(action: {
                isPasswordFocused = false
                Task {
                    await viewModel.authenticate()
                }
            }) {
                Text("Authenticate")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(viewModel.password.isEmpty ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(viewModel.password.isEmpty)
            .padding(.horizontal)
            .padding(.bottom, 40)
            .accessibilityIdentifier("auth.password.submitButton")
        }
        .padding()
        .accessibilityIdentifier("auth.passwordView")
        .onAppear {
            isPasswordFocused = true
        }
    }
}

// MARK: - Auth Success View

struct AuthSuccessView: View {
    @ObservedObject var viewModel: AuthenticationViewModel
    let onDismiss: () -> Void

    @State private var showCheckmark = false
    @State private var showContent = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Success animation
            successIcon

            // Content
            if showContent {
                VStack(spacing: 16) {
                    Text("Authentication Successful")
                        .font(.title)
                        .fontWeight(.bold)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .accessibilityIdentifier("auth.success.title")

                    Text("Your credentials have been securely rotated.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                        .accessibilityIdentifier("auth.success.subtitle")

                    // Rotation info
                    if case .credentialRotated(let latVersion) = viewModel.state {
                        rotationInfo(latVersion: latVersion)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal)
            }

            Spacer()

            // Continue button
            if showContent {
                Button(action: onDismiss) {
                    Text("Continue")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityIdentifier("auth.success.continueButton")
            }
        }
        .accessibilityIdentifier("auth.successView")
        .onAppear {
            animateIn()
        }
    }

    // MARK: - Success Icon

    private var successIcon: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.15))
                .frame(width: 140, height: 140)
                .scaleEffect(showCheckmark ? 1 : 0.5)
                .opacity(showCheckmark ? 1 : 0)

            Circle()
                .stroke(Color.green, lineWidth: 4)
                .frame(width: 120, height: 120)
                .scaleEffect(showCheckmark ? 1 : 0.5)
                .opacity(showCheckmark ? 1 : 0)

            Image(systemName: "checkmark")
                .font(.system(size: 50, weight: .bold))
                .foregroundStyle(.green)
                .scaleEffect(showCheckmark ? 1 : 0)
                .opacity(showCheckmark ? 1 : 0)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showCheckmark)
        .accessibilityIdentifier("auth.success.icon")
    }

    // MARK: - Rotation Info

    private func rotationInfo(latVersion: Int) -> some View {
        VStack(spacing: 12) {
            Text("Security Keys Rotated")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("auth.success.rotationTitle")

            VStack {
                Text("LAT Version")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("v\(latVersion)")
                    .font(.headline)
                    .foregroundStyle(.green)
            }
            .accessibilityIdentifier("auth.success.latVersion")
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .accessibilityIdentifier("auth.success.rotationInfo")
    }

    // MARK: - Animation

    private func animateIn() {
        withAnimation(.easeOut(duration: 0.4)) {
            showCheckmark = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeOut(duration: 0.4)) {
                showContent = true
            }
        }
    }
}

// MARK: - Preview

#Preview {
    AuthenticationContainerView()
        .environmentObject(AppState())
}
