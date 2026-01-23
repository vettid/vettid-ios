import SwiftUI

/// Full contract review and signing view
/// (Issue #12: Contract review screen)
struct ContractSigningView: View {
    let serviceInfo: ServiceConnectionInfo
    let offerings: [ContractOffering]
    let onConnect: (ContractOffering, Set<String>) async -> Void
    let onCancel: () -> Void

    @State private var selectedOffering: ContractOffering?
    @State private var enabledOptionalFields: Set<String> = []
    @State private var termsAccepted = false
    @State private var showingPasswordPrompt = false
    @State private var isConnecting = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    init(
        serviceInfo: ServiceConnectionInfo,
        offerings: [ContractOffering],
        onConnect: @escaping (ContractOffering, Set<String>) async -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.serviceInfo = serviceInfo
        self.offerings = offerings
        self.onConnect = onConnect
        self.onCancel = onCancel
        self._selectedOffering = State(initialValue: offerings.first)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Service info header
                    serviceHeader

                    // Offering selection
                    if offerings.count > 1 {
                        offeringSelectionSection
                    }

                    // Capabilities requested
                    if let offering = selectedOffering {
                        capabilitiesSection(offering)
                    }

                    // Data requirements
                    if let offering = selectedOffering {
                        dataRequirementsSection(offering)
                    }

                    // Terms acceptance
                    termsSection

                    // Error message
                    if let error = errorMessage {
                        errorBanner(error)
                    }

                    // Sign button
                    signButton
                }
                .padding()
            }
            .navigationTitle("Review Contract")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .sheet(isPresented: $showingPasswordPrompt) {
                ContractSigningPasswordPrompt(
                    serviceName: serviceInfo.name,
                    onAuthorize: { password in
                        await signContract(password: password)
                    },
                    onCancel: {
                        showingPasswordPrompt = false
                    }
                )
                .interactiveDismissDisabled(isConnecting)
            }
        }
    }

    // MARK: - Service Header

    private var serviceHeader: some View {
        HStack(spacing: 16) {
            // Logo
            if let logoUrl = serviceInfo.logoUrl, let url = URL(string: logoUrl) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    servicePlaceholder
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                servicePlaceholder
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(serviceInfo.name)
                        .font(.headline)

                    if serviceInfo.domainVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                    }
                }

                if let domain = serviceInfo.domain {
                    Text(domain)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var servicePlaceholder: some View {
        ZStack {
            Color(UIColor.tertiarySystemBackground)
            Image(systemName: "building.2.fill")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Offering Selection

    private var offeringSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Plan")
                .font(.headline)

            ForEach(offerings) { offering in
                OfferingSelectionRow(
                    offering: offering,
                    isSelected: selectedOffering?.id == offering.id
                ) {
                    withAnimation {
                        selectedOffering = offering
                        // Reset optional fields when changing offering
                        enabledOptionalFields = []
                    }
                }
            }
        }
    }

    // MARK: - Capabilities Section

    private func capabilitiesSection(_ offering: ContractOffering) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions Requested")
                .font(.headline)

            VStack(spacing: 8) {
                ForEach(offering.capabilities, id: \.self) { capability in
                    ContractCapabilityRow(capability: capability)
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
    }

    // MARK: - Data Requirements Section

    private func dataRequirementsSection(_ offering: ContractOffering) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Data Requirements")
                .font(.headline)

            VStack(spacing: 0) {
                // Required fields
                if !offering.requiredFields.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Required")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                            .padding(.horizontal)
                            .padding(.top, 12)

                        ForEach(offering.requiredFields, id: \.self) { field in
                            DataFieldRow(
                                field: field,
                                isRequired: true,
                                isEnabled: true,
                                onToggle: nil
                            )
                        }
                    }
                }

                // Optional fields
                if !offering.optionalFields.isEmpty {
                    Divider()
                        .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Optional")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                            .padding(.horizontal)

                        ForEach(offering.optionalFields, id: \.self) { field in
                            DataFieldRow(
                                field: field,
                                isRequired: false,
                                isEnabled: enabledOptionalFields.contains(field),
                                onToggle: {
                                    if enabledOptionalFields.contains(field) {
                                        enabledOptionalFields.remove(field)
                                    } else {
                                        enabledOptionalFields.insert(field)
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .padding(.bottom, 12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
    }

    // MARK: - Terms Section

    private var termsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Terms checkbox
            Button {
                termsAccepted.toggle()
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: termsAccepted ? "checkmark.square.fill" : "square")
                        .foregroundColor(termsAccepted ? .blue : .secondary)
                        .font(.title3)

                    Text("I have read and agree to the Terms of Service and Privacy Policy")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)

            // Links
            HStack(spacing: 16) {
                Link(destination: URL(string: "https://example.com/terms")!) {
                    Label("Terms of Service", systemImage: "doc.text")
                        .font(.caption)
                }

                Link(destination: URL(string: "https://example.com/privacy")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.red)

            Spacer()
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Sign Button

    private var signButton: some View {
        VStack(spacing: 12) {
            Button {
                showingPasswordPrompt = true
            } label: {
                HStack {
                    Image(systemName: "signature")
                    Text("Sign & Connect")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSign)

            if !termsAccepted {
                Text("Please accept the terms to continue")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Password required to sign the contract")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var canSign: Bool {
        termsAccepted && selectedOffering != nil
    }

    // MARK: - Contract Signing

    private func signContract(password: String) async {
        guard let offering = selectedOffering else { return }

        isConnecting = true
        errorMessage = nil

        do {
            // Verify password (in production, this goes through the authorization service)
            try await verifyPassword(password)

            // Execute connection
            await onConnect(offering, enabledOptionalFields)

            showingPasswordPrompt = false
        } catch {
            errorMessage = error.localizedDescription
            isConnecting = false
        }
    }

    private func verifyPassword(_ password: String) async throws {
        // In production, this would use OperationAuthorizationService
        #if DEBUG
        try await Task.sleep(nanoseconds: 500_000_000)

        // Simulate password verification
        if password.isEmpty {
            throw ContractSigningError.authenticationFailed
        }
        #endif
    }
}

// MARK: - Contract Signing Password Prompt

struct ContractSigningPasswordPrompt: View {
    let serviceName: String
    let onAuthorize: (String) async -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var isAuthorizing = false
    @State private var errorMessage: String?
    @State private var showPassword = false
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Icon and info
                VStack(spacing: 16) {
                    Image(systemName: "signature")
                        .font(.system(size: 48))
                        .foregroundStyle(.blue)

                    Text("Sign Contract")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Enter your password to sign the contract with \(serviceName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top)

                // Info box
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Your signature confirms your agreement to share the selected data with this service.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(12)

                // Password field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Password")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack {
                        if showPassword {
                            TextField("Enter password", text: $password)
                                .textContentType(.password)
                                .focused($isPasswordFocused)
                        } else {
                            SecureField("Enter password", text: $password)
                                .textContentType(.password)
                                .focused($isPasswordFocused)
                        }

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                }

                // Error message
                if let error = errorMessage {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                // Action buttons
                VStack(spacing: 12) {
                    Button {
                        attemptAuthorization()
                    } label: {
                        HStack {
                            if isAuthorizing {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "signature")
                                Text("Sign Contract")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(password.isEmpty ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(password.isEmpty || isAuthorizing)

                    Button("Cancel") {
                        onCancel()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Authorize Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
            .onAppear {
                isPasswordFocused = true
            }
        }
    }

    private func attemptAuthorization() {
        guard !password.isEmpty else { return }

        isAuthorizing = true
        errorMessage = nil

        Task {
            await onAuthorize(password)
            isAuthorizing = false
        }
    }
}

// MARK: - Offering Selection Row

struct OfferingSelectionRow: View {
    let offering: ContractOffering
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(offering.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    if let description = offering.description {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if let price = offering.price {
                    Text(price)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .secondary)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Capability Row

struct ContractCapabilityRow: View {
    let capability: String  // Raw capability type string

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: capabilityIcon)
                .foregroundColor(capabilityColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(capabilityDisplayName)
                    .font(.subheadline)

                Text(capabilityDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var capabilityIcon: String {
        switch capability {
        case "read_profile": return "person.fill"
        case "read_email": return "envelope.fill"
        case "read_phone": return "phone.fill"
        case "read_address": return "location.fill"
        case "send_messages": return "message.fill"
        case "request_auth": return "person.badge.key.fill"
        case "request_payment": return "creditcard.fill"
        case "store_data": return "externaldrive.fill"
        case "initiate_call": return "phone.arrow.up.right.fill"
        default: return "questionmark.circle"
        }
    }

    private var capabilityColor: Color {
        switch capability {
        case "read_profile", "read_email", "read_phone", "read_address":
            return .blue
        case "send_messages", "initiate_call":
            return .green
        case "request_auth":
            return .purple
        case "request_payment":
            return .orange
        case "store_data":
            return .pink
        default:
            return .secondary
        }
    }

    private var capabilityDisplayName: String {
        switch capability {
        case "read_profile": return "Read Profile"
        case "read_email": return "Read Email"
        case "read_phone": return "Read Phone"
        case "read_address": return "Read Address"
        case "send_messages": return "Send Messages"
        case "request_auth": return "Request Authentication"
        case "request_payment": return "Request Payment"
        case "store_data": return "Store Data"
        case "initiate_call": return "Initiate Calls"
        default: return capability.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var capabilityDescription: String {
        switch capability {
        case "read_profile": return "Access your display name"
        case "read_email": return "Access your email address"
        case "read_phone": return "Access your phone number"
        case "read_address": return "Access your physical address"
        case "send_messages": return "Send you notifications"
        case "request_auth": return "Request login verification"
        case "request_payment": return "Request payments"
        case "store_data": return "Store data in your vault"
        case "initiate_call": return "Start voice or video calls"
        default: return "Service functionality"
        }
    }
}

// MARK: - Data Field Row

struct DataFieldRow: View {
    let field: String
    let isRequired: Bool
    let isEnabled: Bool
    let onToggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fieldIcon)
                .foregroundColor(isRequired ? .orange : .blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(fieldDisplayName)
                    .font(.subheadline)

                Text(fieldPurpose)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isRequired {
                Text("Required")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
            } else if let onToggle = onToggle {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { _ in onToggle() }
                ))
                .labelsHidden()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var fieldIcon: String {
        switch field {
        case "email": return "envelope.fill"
        case "display_name": return "person.fill"
        case "phone": return "phone.fill"
        case "address": return "location.fill"
        default: return "doc.fill"
        }
    }

    private var fieldDisplayName: String {
        switch field {
        case "email": return "Email Address"
        case "display_name": return "Display Name"
        case "phone": return "Phone Number"
        case "address": return "Physical Address"
        default: return field.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var fieldPurpose: String {
        switch field {
        case "email": return "For account identification and notifications"
        case "display_name": return "For personalization"
        case "phone": return "For two-factor authentication"
        case "address": return "For shipping and delivery"
        default: return "Service functionality"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ContractSigningView_Previews: PreviewProvider {
    static var previews: some View {
        ContractSigningView(
            serviceInfo: ServiceConnectionInfo(
                id: "test-1",
                name: "Example Service",
                description: "A sample service for testing",
                logoUrl: nil,
                domain: "example.com",
                domainVerified: true,
                category: ServiceCategory.technology
            ),
            offerings: [
                ContractOffering(
                    id: "basic",
                    name: "Basic",
                    description: "Essential features",
                    price: "Free",
                    requiredFields: ["email", "display_name"],
                    optionalFields: ["phone"],
                    capabilities: ["read_email", "send_messages"]
                ),
                ContractOffering(
                    id: "premium",
                    name: "Premium",
                    description: "Full access",
                    price: "$9.99/mo",
                    requiredFields: ["email", "display_name", "phone"],
                    optionalFields: ["address"],
                    capabilities: ["read_email", "read_phone", "send_messages", "request_auth"]
                )
            ],
            onConnect: { _, _ in },
            onCancel: {}
        )
    }
}
#endif
