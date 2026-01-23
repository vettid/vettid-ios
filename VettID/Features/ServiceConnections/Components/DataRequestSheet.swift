import SwiftUI
import LocalAuthentication

/// Sheet displaying a data request from a service
/// Used when a service requests specific data fields from the user
struct DataRequestSheet: View {
    let request: ServiceDataRequest
    @Binding var isPresented: Bool
    let onDecision: (DataRequestDecision) async -> Void

    @State private var selectedFields: Set<String> = []
    @State private var isProcessing = false
    @State private var error: String?
    @State private var timeRemaining: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        // Service Header
                        serviceHeader

                        // Request Details
                        requestDetails

                        // Field Selection
                        fieldSelection

                        // Purpose
                        purposeSection

                        // Expiration
                        expirationBanner
                    }
                    .padding()
                }

                // Error message
                if let error = error {
                    errorBanner(error)
                }

                // Action Buttons
                actionButtons
                    .padding()
            }
            .navigationTitle("Data Request")
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
            // Pre-select all required fields
            selectedFields = Set(request.requiredFields.map { $0.field })
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

    // MARK: - Request Details

    private var requestDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Requesting your data")
                .font(.headline)

            Text("This service is requesting access to the following information from your vault.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Field Selection

    private var fieldSelection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Required fields
            if !request.requiredFields.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Required", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)

                    ForEach(request.requiredFields) { field in
                        DataFieldRow(
                            field: field,
                            isRequired: true,
                            isSelected: true,
                            onToggle: nil
                        )
                    }
                }
            }

            // Optional fields
            if !request.optionalFields.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Optional", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundColor(.blue)

                    ForEach(request.optionalFields) { field in
                        DataFieldRow(
                            field: field,
                            isRequired: false,
                            isSelected: selectedFields.contains(field.field),
                            onToggle: {
                                toggleField(field.field)
                            }
                        )
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
    }

    private func toggleField(_ fieldId: String) {
        if selectedFields.contains(fieldId) {
            selectedFields.remove(fieldId)
        } else {
            selectedFields.insert(fieldId)
        }
    }

    // MARK: - Purpose Section

    private var purposeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Purpose")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(request.purpose)
                .font(.subheadline)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

            // Share Button
            Button(action: {
                Task {
                    await handleShare()
                }
            }) {
                HStack {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    Text("Share Data")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isProcessing || timeRemaining <= 0)
        }
    }

    // MARK: - Actions

    private func startExpirationTimer() {
        timeRemaining = request.expiresAt.timeIntervalSinceNow

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            timeRemaining = request.expiresAt.timeIntervalSinceNow
            if timeRemaining <= 0 {
                timer?.invalidate()
            }
        }
    }

    private func handleShare() async {
        isProcessing = true
        error = nil

        // Require biometric authentication
        let context = LAContext()
        var authError: NSError?

        let canUseBiometrics = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &authError
        )

        let policy: LAPolicy = canUseBiometrics ?
            .deviceOwnerAuthenticationWithBiometrics :
            .deviceOwnerAuthentication

        do {
            let success = try await context.evaluatePolicy(
                policy,
                localizedReason: "Authenticate to share your data with \(request.serviceName)"
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
    }

    private func handleDecision(approved: Bool) async {
        isProcessing = true

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(approved ? .success : .warning)

        let decision = DataRequestDecision(
            requestId: request.id,
            approved: approved,
            sharedFields: approved ? Array(selectedFields) : [],
            respondedAt: Date()
        )

        await onDecision(decision)
        isPresented = false
    }
}

// MARK: - Data Field Row

struct DataFieldRow: View {
    let field: FieldSpec
    let isRequired: Bool
    let isSelected: Bool
    let onToggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Field icon
            Image(systemName: field.fieldType.icon)
                .foregroundColor(isRequired ? .orange : .blue)
                .frame(width: 24)

            // Field info
            VStack(alignment: .leading, spacing: 2) {
                Text(field.fieldType.displayLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(field.purpose)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Selection indicator
            if isRequired {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let onToggle = onToggle {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .blue : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(
            isRequired ?
                Color.orange.opacity(0.05) :
                (isSelected ? Color.blue.opacity(0.05) : Color.clear)
        )
        .cornerRadius(12)
    }
}

// MARK: - Data Request Types

/// Data request from a service
struct ServiceDataRequest: Codable, Identifiable {
    let id: String
    let serviceId: String
    let serviceName: String
    let serviceLogoUrl: String?
    let domainVerified: Bool
    let requiredFields: [FieldSpec]
    let optionalFields: [FieldSpec]
    let purpose: String
    let requestedAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "request_id"
        case serviceId = "service_id"
        case serviceName = "service_name"
        case serviceLogoUrl = "service_logo_url"
        case domainVerified = "domain_verified"
        case requiredFields = "required_fields"
        case optionalFields = "optional_fields"
        case purpose
        case requestedAt = "requested_at"
        case expiresAt = "expires_at"
    }
}

/// Decision on a data request
struct DataRequestDecision: Codable {
    let requestId: String
    let approved: Bool
    let sharedFields: [String]
    let respondedAt: Date

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case approved
        case sharedFields = "shared_fields"
        case respondedAt = "responded_at"
    }
}

// MARK: - Preview

#if DEBUG
struct DataRequestSheet_Previews: PreviewProvider {
    static var previews: some View {
        DataRequestSheet(
            request: ServiceDataRequest(
                id: "test-request",
                serviceId: "service-123",
                serviceName: "Example Store",
                serviceLogoUrl: nil,
                domainVerified: true,
                requiredFields: [
                    FieldSpec(field: "email", purpose: "Order confirmation", retention: "30 days"),
                    FieldSpec(field: "display_name", purpose: "Personalization", retention: "Until deletion")
                ],
                optionalFields: [
                    FieldSpec(field: "phone", purpose: "Delivery updates", retention: "7 days"),
                    FieldSpec(field: "address", purpose: "Shipping", retention: "30 days")
                ],
                purpose: "Complete your purchase and receive order updates",
                requestedAt: Date(),
                expiresAt: Date().addingTimeInterval(120)
            ),
            isPresented: .constant(true),
            onDecision: { _ in }
        )
    }
}
#endif
