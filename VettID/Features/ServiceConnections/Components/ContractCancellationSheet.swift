import SwiftUI
import LocalAuthentication

/// Sheet for cancelling/revoking a service connection
struct ContractCancellationSheet: View {
    let connection: ServiceConnectionRecord
    @Binding var isPresented: Bool
    let onCancellation: (ContractCancellation) async -> Void

    @State private var cancellationReason: CancellationReason = .noLongerNeeded
    @State private var customReason = ""
    @State private var deleteStoredData = true
    @State private var isProcessing = false
    @State private var error: String?
    @State private var showingConfirmation = false

    var body: some View {
        NavigationView {
            Form {
                // Service info section
                serviceInfoSection

                // Reason selection
                reasonSection

                // Data handling section
                dataHandlingSection

                // Warning section
                warningSection

                // Cancel button
                cancelButtonSection
            }
            .navigationTitle("Cancel Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        isPresented = false
                    }
                    .disabled(isProcessing)
                }
            }
            .alert("Confirm Cancellation", isPresented: $showingConfirmation) {
                Button("Cancel Connection", role: .destructive) {
                    Task {
                        await performCancellation()
                    }
                }
                Button("Go Back", role: .cancel) {}
            } message: {
                Text("This will permanently disconnect you from \(connection.serviceProfile.serviceName). This action cannot be undone.")
            }
            .alert("Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                if let error = error {
                    Text(error)
                }
            }
        }
    }

    // MARK: - Service Info Section

    private var serviceInfoSection: some View {
        Section {
            HStack(spacing: 16) {
                // Logo
                if let logoUrl = connection.serviceProfile.serviceLogoUrl,
                   let url = URL(string: logoUrl) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        placeholderLogo
                    }
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    placeholderLogo
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.serviceProfile.serviceName)
                        .font(.headline)

                    Text("Connected \(connection.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var placeholderLogo: some View {
        ZStack {
            Color(UIColor.secondarySystemBackground)
            Image(systemName: connection.serviceProfile.serviceCategory.icon)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Reason Section

    private var reasonSection: some View {
        Section {
            Picker("Reason", selection: $cancellationReason) {
                ForEach(CancellationReason.allCases, id: \.self) { reason in
                    Text(reason.displayName).tag(reason)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            if cancellationReason == .other {
                TextField("Please specify...", text: $customReason, axis: .vertical)
                    .lineLimit(3...6)
            }
        } header: {
            Text("Why are you cancelling?")
        } footer: {
            Text("This feedback helps services improve.")
        }
    }

    // MARK: - Data Handling Section

    private var dataHandlingSection: some View {
        Section {
            Toggle(isOn: $deleteStoredData) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Delete Stored Data")
                        .font(.subheadline)

                    Text("Request the service delete any data they have stored about you")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Data Handling")
        } footer: {
            if deleteStoredData {
                Text("The service is required to delete your data within 30 days of your request.")
            } else {
                Text("The service may retain your data according to their privacy policy.")
            }
        }
    }

    // MARK: - Warning Section

    private var warningSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("What happens when you cancel", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 8) {
                    warningItem("You'll lose access to the service's features")
                    warningItem("Pending requests will be automatically denied")
                    warningItem("You'll need to reconnect to use the service again")

                    if deleteStoredData {
                        warningItem("Your stored data will be requested for deletion")
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func warningItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundColor(.secondary)
                .padding(.top, 6)

            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Cancel Button Section

    private var cancelButtonSection: some View {
        Section {
            Button(action: {
                showingConfirmation = true
            }) {
                HStack {
                    Spacer()
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Image(systemName: "xmark.circle.fill")
                        Text("Cancel Connection")
                    }
                    Spacer()
                }
            }
            .foregroundColor(.red)
            .disabled(isProcessing || (cancellationReason == .other && customReason.isEmpty))
        }
    }

    // MARK: - Actions

    private func performCancellation() async {
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
                localizedReason: "Authenticate to cancel your connection with \(connection.serviceProfile.serviceName)"
            )

            if success {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.warning)

                let cancellation = ContractCancellation(
                    connectionId: connection.id,
                    reason: cancellationReason,
                    customReason: cancellationReason == .other ? customReason : nil,
                    deleteStoredData: deleteStoredData,
                    cancelledAt: Date()
                )

                await onCancellation(cancellation)
                isPresented = false
            } else {
                error = "Authentication failed"
                isProcessing = false
            }
        } catch {
            self.error = error.localizedDescription
            isProcessing = false
        }
    }
}

// MARK: - Cancellation Types

/// Reasons for cancelling a connection
enum CancellationReason: String, Codable, CaseIterable {
    case noLongerNeeded = "no_longer_needed"
    case privacyConcerns = "privacy_concerns"
    case tooManyRequests = "too_many_requests"
    case poorExperience = "poor_experience"
    case switchingService = "switching_service"
    case other

    var displayName: String {
        switch self {
        case .noLongerNeeded: return "I no longer need this service"
        case .privacyConcerns: return "Privacy concerns"
        case .tooManyRequests: return "Too many requests/notifications"
        case .poorExperience: return "Poor experience with the service"
        case .switchingService: return "Switching to a different service"
        case .other: return "Other reason"
        }
    }
}

/// Contract cancellation request
struct ContractCancellation: Codable {
    let connectionId: String
    let reason: CancellationReason
    let customReason: String?
    let deleteStoredData: Bool
    let cancelledAt: Date

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case reason
        case customReason = "custom_reason"
        case deleteStoredData = "delete_stored_data"
        case cancelledAt = "cancelled_at"
    }
}

// MARK: - Revocation Confirmation View

/// View shown after successful cancellation
struct ConnectionRevokedView: View {
    let serviceName: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            VStack(spacing: 8) {
                Text("Connection Cancelled")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("You've been disconnected from \(serviceName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                infoItem(icon: "checkmark", text: "Connection revoked")
                infoItem(icon: "bell.slash", text: "No more notifications")
                infoItem(icon: "clock", text: "Data deletion requested")
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(16)

            Spacer()

            Button("Done") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .padding()
    }

    private func infoItem(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.green)
                .frame(width: 24)

            Text(text)
                .font(.subheadline)

            Spacer()
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ContractCancellationSheet_Previews: PreviewProvider {
    static var previews: some View {
        ContractCancellationSheet(
            connection: ServiceConnectionRecord(
                id: "conn-123",
                serviceGuid: "service-123",
                serviceProfile: ServiceProfile(
                    id: "service-123",
                    serviceName: "Example Store",
                    serviceDescription: "A sample store",
                    serviceLogoUrl: nil,
                    serviceCategory: .retail,
                    organization: OrganizationInfo(
                        name: "Example Inc.",
                        verified: true,
                        verificationType: .business,
                        verifiedAt: Date(),
                        registrationId: nil,
                        country: "US"
                    ),
                    contactInfo: ServiceContactInfo(
                        emails: [],
                        phoneNumbers: [],
                        address: nil,
                        supportUrl: nil,
                        supportEmail: nil,
                        supportPhone: nil
                    ),
                    trustedResources: [],
                    currentContract: ServiceDataContract(
                        id: "contract-1",
                        serviceGuid: "service-123",
                        version: 1,
                        title: "Standard Agreement",
                        description: "Basic data sharing",
                        termsUrl: nil,
                        privacyUrl: nil,
                        requiredFields: [],
                        optionalFields: [],
                        onDemandFields: [],
                        consentFields: [],
                        canStoreData: false,
                        storageCategories: [],
                        canSendMessages: true,
                        canRequestAuth: true,
                        canRequestPayment: false,
                        maxRequestsPerHour: nil,
                        maxStorageMB: nil,
                        createdAt: Date(),
                        expiresAt: nil
                    ),
                    profileVersion: 1,
                    updatedAt: Date()
                ),
                contractId: "contract-1",
                contractVersion: 1,
                contractAcceptedAt: Date().addingTimeInterval(-86400 * 30)
            ),
            isPresented: .constant(true),
            onCancellation: { _ in }
        )
    }
}
#endif
