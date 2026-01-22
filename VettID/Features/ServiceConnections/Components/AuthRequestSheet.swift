import SwiftUI
import LocalAuthentication

/// Sheet displaying an authentication request from a service
/// Used when a service needs to verify the user's identity
struct AuthRequestSheet: View {
    let request: ServiceAuthRequest
    @Binding var isPresented: Bool
    let onDecision: (Bool) async -> Void

    @State private var isProcessing = false
    @State private var error: String?
    @State private var timeRemaining: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Service Header
                serviceHeader

                // Purpose
                purposeSection

                // Scopes (if any)
                if !request.scopes.isEmpty {
                    scopesSection
                }

                // Expiration
                expirationBanner

                Spacer()

                // Error message
                if let error = error {
                    errorBanner(error)
                }

                // Action Buttons
                actionButtons
            }
            .padding()
            .navigationTitle("Authentication Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .disabled(isProcessing)
                }
            }
        }
        .onAppear {
            startExpirationTimer()
        }
        .onDisappear {
            timer?.invalidate()
        }
        .interactiveDismissDisabled(isProcessing)
    }

    // MARK: - Service Header

    private var serviceHeader: some View {
        HStack(spacing: 16) {
            // Service logo
            if let logoUrl = request.serviceLogoUrl, let url = URL(string: logoUrl) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    Image(systemName: "building.2.fill")
                        .font(.title)
                        .foregroundColor(.secondary)
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "building.2.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.secondary)
                    .frame(width: 60, height: 60)
                    .background(Color(UIColor.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(request.serviceName)
                    .font(.title2)
                    .fontWeight(.semibold)

                if request.domainVerified {
                    Label("Verified", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }

            Spacer()
        }
    }

    // MARK: - Purpose Section

    private var purposeSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 40))
                .foregroundColor(.blue)

            Text("Wants to verify your identity")
                .font(.headline)

            Text(request.purpose)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
    }

    // MARK: - Scopes Section

    private var scopesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Requested Access")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(request.scopes, id: \.self) { scope in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text(formatScope(scope))
                            .font(.subheadline)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Expiration Banner

    private var expirationBanner: some View {
        HStack {
            Image(systemName: "clock")
                .foregroundColor(timeRemaining < 30 ? .red : .secondary)

            Text("Expires in \(formattedTimeRemaining)")
                .font(.caption)
                .foregroundColor(timeRemaining < 30 ? .red : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(timeRemaining < 30 ? Color.red.opacity(0.1) : Color(UIColor.tertiarySystemBackground))
        .cornerRadius(8)
    }

    private var formattedTimeRemaining: String {
        if timeRemaining <= 0 { return "Expired" }
        let minutes = Int(timeRemaining / 60)
        let seconds = Int(timeRemaining.truncatingRemainder(dividingBy: 60))
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 16) {
            // Deny Button
            Button(action: {
                Task {
                    await handleDecision(approved: false)
                }
            }) {
                Text("Deny")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isProcessing || timeRemaining <= 0)

            // Approve Button
            Button(action: {
                Task {
                    await handleApprove()
                }
            }) {
                HStack {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    Text("Approve")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isProcessing || timeRemaining <= 0)
        }
    }

    // MARK: - Helpers

    private func startExpirationTimer() {
        timeRemaining = request.expiresAt.timeIntervalSinceNow

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            timeRemaining = request.expiresAt.timeIntervalSinceNow
            if timeRemaining <= 0 {
                timer?.invalidate()
            }
        }
    }

    private func formatScope(_ scope: String) -> String {
        // Convert snake_case to Title Case
        scope.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func handleApprove() async {
        isProcessing = true
        error = nil

        // Require biometric authentication
        let context = LAContext()
        var authError: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
            // Fall back to passcode
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Authenticate to approve request from \(request.serviceName)"
                )
                if success {
                    await handleDecision(approved: true)
                } else {
                    error = "Authentication failed"
                    isProcessing = false
                }
            } catch {
                self.error = error.localizedDescription
                isProcessing = false
            }
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Authenticate to approve request from \(request.serviceName)"
            )
            if success {
                await handleDecision(approved: true)
            } else {
                error = "Biometric authentication failed"
                isProcessing = false
            }
        } catch {
            self.error = error.localizedDescription
            isProcessing = false
        }
    }

    private func handleDecision(approved: Bool) async {
        isProcessing = true

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(approved ? .success : .warning)

        await onDecision(approved)
        isPresented = false
    }
}

// MARK: - Preview

#if DEBUG
struct AuthRequestSheet_Previews: PreviewProvider {
    static var previews: some View {
        AuthRequestSheet(
            request: ServiceAuthRequest(
                id: "test-request",
                serviceId: "service-123",
                serviceName: "Example Bank",
                serviceLogoUrl: nil,
                domainVerified: true,
                purpose: "Sign in to your banking account",
                scopes: ["read_profile", "verify_identity"],
                requestedAt: Date(),
                expiresAt: Date().addingTimeInterval(120)
            ),
            isPresented: .constant(true),
            onDecision: { _ in }
        )
    }
}
#endif
