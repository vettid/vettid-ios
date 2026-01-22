import SwiftUI
import LocalAuthentication

/// Sheet displaying an authorization request from a service
/// Used when a service wants to perform a specific action (e.g., payment, data access)
struct AuthzRequestSheet: View {
    let request: ServiceAuthzRequest
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

                // Action Details Card
                actionCard

                // Context Details (if any)
                if !request.context.isEmpty {
                    contextSection
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
            .navigationTitle("Authorization Request")
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

    // MARK: - Action Card

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Text("Wants to:")
                .font(.headline)
                .foregroundColor(.secondary)

            // Action
            HStack {
                Image(systemName: iconForAction(request.action))
                    .font(.title2)
                    .foregroundColor(colorForAction(request.action))
                    .frame(width: 44, height: 44)
                    .background(colorForAction(request.action).opacity(0.15))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(formatAction(request.action))
                        .font(.title3)
                        .fontWeight(.semibold)

                    if let resource = request.resource {
                        Text("On: \(resource)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Amount (if financial action)
            if let amount = request.context["amount"] {
                Divider()

                HStack {
                    Text("Amount:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(amount)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(colorForAction(request.action))
                }
            }

            // Purpose
            if !request.purpose.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Purpose")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(request.purpose)
                        .font(.subheadline)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
    }

    // MARK: - Context Section

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(filteredContext.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack {
                        Text(formatContextKey(key))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(value)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    /// Filter out amount (shown separately) and other internal fields
    private var filteredContext: [String: String] {
        request.context.filter { key, _ in
            !["amount", "_internal", "_signature"].contains(key)
        }
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
            .tint(colorForAction(request.action))
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

    private func formatAction(_ action: String) -> String {
        // Convert snake_case to Title Case
        action.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func formatContextKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func iconForAction(_ action: String) -> String {
        let actionLower = action.lowercased()
        if actionLower.contains("payment") || actionLower.contains("pay") {
            return "creditcard.fill"
        } else if actionLower.contains("transfer") {
            return "arrow.right.arrow.left"
        } else if actionLower.contains("data") || actionLower.contains("access") {
            return "doc.text.fill"
        } else if actionLower.contains("delete") || actionLower.contains("remove") {
            return "trash.fill"
        } else if actionLower.contains("sign") {
            return "signature"
        } else if actionLower.contains("share") {
            return "square.and.arrow.up"
        } else {
            return "checkmark.shield.fill"
        }
    }

    private func colorForAction(_ action: String) -> Color {
        let actionLower = action.lowercased()
        if actionLower.contains("payment") || actionLower.contains("pay") || actionLower.contains("transfer") {
            return .orange
        } else if actionLower.contains("delete") || actionLower.contains("remove") {
            return .red
        } else {
            return .blue
        }
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
                    localizedReason: "Authenticate to approve \(formatAction(request.action)) request from \(request.serviceName)"
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
                localizedReason: "Authenticate to approve \(formatAction(request.action)) request from \(request.serviceName)"
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
struct AuthzRequestSheet_Previews: PreviewProvider {
    static var previews: some View {
        AuthzRequestSheet(
            request: ServiceAuthzRequest(
                id: "test-request",
                serviceId: "service-123",
                serviceName: "Example Store",
                serviceLogoUrl: nil,
                domainVerified: true,
                action: "process_payment",
                resource: "Order #12345",
                context: [
                    "amount": "$49.99",
                    "merchant": "Example Store",
                    "card_ending": "4242"
                ],
                purpose: "Complete your purchase",
                requestedAt: Date(),
                expiresAt: Date().addingTimeInterval(120)
            ),
            isPresented: .constant(true),
            onDecision: { _ in }
        )
    }
}
#endif
