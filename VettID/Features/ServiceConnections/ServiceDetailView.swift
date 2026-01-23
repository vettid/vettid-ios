import SwiftUI

/// Detailed view of a service from the directory
/// Shows service info, contract details, and connect action
struct ServiceDetailView: View {
    let service: ServiceDirectoryEntry
    @StateObject private var viewModel: ServiceDetailViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingContractReview = false

    init(service: ServiceDirectoryEntry) {
        self.service = service
        self._viewModel = StateObject(wrappedValue: ServiceDetailViewModel(serviceId: service.id))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                serviceHeader

                // Description
                descriptionSection

                // Organization info
                organizationSection

                // Trust indicators
                trustSection

                // Contract preview
                if let profile = viewModel.serviceProfile {
                    contractPreviewSection(profile.currentContract)
                }

                // Connect button
                connectButton
            }
            .padding()
        }
        .navigationTitle("Service Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        // Report service
                    } label: {
                        Label("Report Issue", systemImage: "exclamationmark.bubble")
                    }

                    Button {
                        // Share service
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await viewModel.loadServiceDetails()
        }
        .sheet(isPresented: $showingContractReview) {
            if let profile = viewModel.serviceProfile {
                ContractPreviewSheet(
                    serviceProfile: profile,
                    onConnect: {
                        showingContractReview = false
                        // Trigger discovery flow
                    }
                )
            }
        }
    }

    // MARK: - Header

    private var serviceHeader: some View {
        VStack(spacing: 16) {
            // Logo
            serviceLogo
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)

            // Name and verification
            VStack(spacing: 8) {
                HStack {
                    Text(service.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    if service.organization.verified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.blue)
                    }
                }

                // Category badge
                HStack {
                    Image(systemName: service.category.icon)
                    Text(service.category.displayName)
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(16)
            }

            // Stats row
            HStack(spacing: 24) {
                statItem(
                    value: formatCount(service.connectionCount),
                    label: "Connections",
                    icon: "person.2.fill"
                )

                if let rating = service.rating {
                    statItem(
                        value: String(format: "%.1f", rating),
                        label: "Rating",
                        icon: "star.fill",
                        iconColor: .yellow
                    )
                }

                if service.featured {
                    statItem(
                        value: "Featured",
                        label: "Status",
                        icon: "star.circle.fill",
                        iconColor: .orange
                    )
                }
            }
        }
    }

    private var serviceLogo: some View {
        Group {
            if let logoUrl = service.logoUrl, let url = URL(string: logoUrl) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    placeholderLogo
                }
            } else {
                placeholderLogo
            }
        }
    }

    private var placeholderLogo: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.2), Color.accentColor.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: service.category.icon)
                .font(.title)
                .foregroundColor(.accentColor)
        }
    }

    private func statItem(value: String, label: String, icon: String, iconColor: Color = .secondary) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                Text(value)
                    .fontWeight(.semibold)
            }
            .font(.subheadline)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Description

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About")
                .font(.headline)

            Text(service.description)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Organization

    private var organizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Organization")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "building.2.fill")
                        .foregroundColor(.secondary)
                    Text(service.organization.name)
                        .font(.subheadline)

                    Spacer()

                    if service.organization.verified {
                        verificationBadge
                    }
                }

                if let country = service.organization.country {
                    HStack {
                        Image(systemName: "globe")
                            .foregroundColor(.secondary)
                        Text(country)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let registrationId = service.organization.registrationId {
                    HStack {
                        Image(systemName: "number")
                            .foregroundColor(.secondary)
                        Text("Registration: \(registrationId)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verificationBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
            Text(service.organization.verificationType?.displayName ?? "Verified")
        }
        .font(.caption)
        .foregroundColor(.blue)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Trust Section

    private var trustSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trust & Safety")
                .font(.headline)

            VStack(spacing: 8) {
                trustItem(
                    icon: "checkmark.shield.fill",
                    title: "Identity Verified",
                    subtitle: "Organization identity has been verified",
                    color: .green,
                    isActive: service.organization.verified
                )

                trustItem(
                    icon: "lock.shield.fill",
                    title: "Encrypted Connection",
                    subtitle: "All data is encrypted end-to-end",
                    color: .blue,
                    isActive: true
                )

                trustItem(
                    icon: "doc.text.fill",
                    title: "Data Contract",
                    subtitle: "Clear terms for data usage",
                    color: .purple,
                    isActive: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trustItem(icon: String, title: String, subtitle: String, color: Color, isActive: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(isActive ? color : .secondary.opacity(0.5))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(isActive ? .primary : .secondary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(color)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Contract Preview

    private func contractPreviewSection(_ contract: ServiceDataContract) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Data Requirements")
                    .font(.headline)

                Spacer()

                Button("View Full Contract") {
                    showingContractReview = true
                }
                .font(.caption)
            }

            VStack(alignment: .leading, spacing: 8) {
                // Required fields
                if !contract.requiredFields.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Required")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ForEach(contract.requiredFields.prefix(3)) { field in
                            HStack {
                                Image(systemName: field.fieldType.icon)
                                    .foregroundColor(.orange)
                                Text(field.fieldType.displayLabel)
                                    .font(.subheadline)
                            }
                        }

                        if contract.requiredFields.count > 3 {
                            Text("+\(contract.requiredFields.count - 3) more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Optional fields
                if !contract.optionalFields.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Optional")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ForEach(contract.optionalFields.prefix(2)) { field in
                            HStack {
                                Image(systemName: field.fieldType.icon)
                                    .foregroundColor(.blue)
                                Text(field.fieldType.displayLabel)
                                    .font(.subheadline)
                            }
                        }

                        if contract.optionalFields.count > 2 {
                            Text("+\(contract.optionalFields.count - 2) more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Permissions
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Permissions")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 16) {
                        permissionIndicator("Messages", enabled: contract.canSendMessages)
                        permissionIndicator("Auth", enabled: contract.canRequestAuth)
                        permissionIndicator("Payments", enabled: contract.canRequestPayment)
                    }
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionIndicator(_ label: String, enabled: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "minus.circle")
                .foregroundColor(enabled ? .green : .secondary)
            Text(label)
                .font(.caption)
                .foregroundColor(enabled ? .primary : .secondary)
        }
    }

    // MARK: - Connect Button

    private var connectButton: some View {
        VStack(spacing: 12) {
            Button {
                showingContractReview = true
            } label: {
                HStack {
                    Image(systemName: "link")
                    Text("Connect to \(service.name)")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("You'll review the data contract before connecting")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Service Detail ViewModel

@MainActor
final class ServiceDetailViewModel: ObservableObject {
    @Published private(set) var serviceProfile: ServiceProfile?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let serviceId: String
    private let apiClient: APIClient

    init(serviceId: String, apiClient: APIClient = APIClient()) {
        self.serviceId = serviceId
        self.apiClient = apiClient
    }

    func loadServiceDetails() async {
        guard !isLoading else { return }
        isLoading = true

        // For now, use mock data
        #if DEBUG
        await loadMockProfile()
        #endif

        isLoading = false
    }

    #if DEBUG
    private func loadMockProfile() async {
        // Simulate loading
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Create mock profile
        serviceProfile = ServiceProfile(
            id: serviceId,
            serviceName: "Example Service",
            serviceDescription: "A sample service for testing",
            serviceLogoUrl: nil,
            serviceCategory: .technology,
            organization: OrganizationInfo(
                name: "Example Corp",
                verified: true,
                verificationType: .business,
                verifiedAt: Date(),
                registrationId: "EX-12345",
                country: "US"
            ),
            contactInfo: ServiceContactInfo(
                emails: [],
                phoneNumbers: [],
                address: nil,
                supportUrl: "https://example.com/support",
                supportEmail: "support@example.com",
                supportPhone: nil
            ),
            trustedResources: [],
            currentContract: ServiceDataContract(
                id: "contract-1",
                serviceGuid: serviceId,
                version: 1,
                title: "Standard Data Agreement",
                description: "Terms for data sharing",
                termsUrl: "https://example.com/terms",
                privacyUrl: "https://example.com/privacy",
                requiredFields: [
                    FieldSpec(field: "email", purpose: "Account identification", retention: "Until account deletion"),
                    FieldSpec(field: "display_name", purpose: "Personalization", retention: "Until account deletion")
                ],
                optionalFields: [
                    FieldSpec(field: "phone", purpose: "Two-factor authentication", retention: "Until disabled")
                ],
                onDemandFields: [],
                consentFields: [],
                canStoreData: true,
                storageCategories: ["preferences"],
                canSendMessages: true,
                canRequestAuth: true,
                canRequestPayment: false,
                maxRequestsPerHour: 100,
                maxStorageMB: 10,
                createdAt: Date(),
                expiresAt: nil
            ),
            profileVersion: 1,
            updatedAt: Date()
        )
    }
    #endif
}

// MARK: - Contract Preview Sheet

struct ContractPreviewSheet: View {
    let serviceProfile: ServiceProfile
    let onConnect: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Contract title
                    VStack(alignment: .leading, spacing: 8) {
                        Text(serviceProfile.currentContract.title)
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("Version \(serviceProfile.currentContract.version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Description
                    Text(serviceProfile.currentContract.description)
                        .font(.body)
                        .foregroundColor(.secondary)

                    Divider()

                    // Required fields
                    if !serviceProfile.currentContract.requiredFields.isEmpty {
                        fieldSection(
                            title: "Required Information",
                            fields: serviceProfile.currentContract.requiredFields,
                            color: .orange
                        )
                    }

                    // Optional fields
                    if !serviceProfile.currentContract.optionalFields.isEmpty {
                        fieldSection(
                            title: "Optional Information",
                            fields: serviceProfile.currentContract.optionalFields,
                            color: .blue
                        )
                    }

                    // Links
                    if let termsUrl = serviceProfile.currentContract.termsUrl,
                       let privacyUrl = serviceProfile.currentContract.privacyUrl {
                        VStack(alignment: .leading, spacing: 8) {
                            Link(destination: URL(string: termsUrl)!) {
                                Label("Terms of Service", systemImage: "doc.text")
                            }
                            Link(destination: URL(string: privacyUrl)!) {
                                Label("Privacy Policy", systemImage: "hand.raised")
                            }
                        }
                        .font(.subheadline)
                    }
                }
                .padding()
            }
            .navigationTitle("Data Contract")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        onConnect()
                    }
                }
            }
        }
    }

    private func fieldSection(title: String, fields: [FieldSpec], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            ForEach(fields) { field in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: field.fieldType.icon)
                        .foregroundColor(color)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.fieldType.displayLabel)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text(field.purpose)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("Retained: \(field.retention)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ServiceDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ServiceDetailView(
                service: ServiceDirectoryEntry(
                    id: "test-1",
                    name: "Example Service",
                    description: "A sample service for testing the detail view layout and functionality.",
                    logoUrl: nil,
                    category: .technology,
                    organization: OrganizationInfo(
                        name: "Example Corp",
                        verified: true,
                        verificationType: .business,
                        verifiedAt: Date(),
                        registrationId: "EX-12345",
                        country: "US"
                    ),
                    connectionCount: 12500,
                    rating: 4.7,
                    featured: true
                )
            )
        }
    }
}
#endif
