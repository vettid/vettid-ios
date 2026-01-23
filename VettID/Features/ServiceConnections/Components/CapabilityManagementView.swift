import SwiftUI
import LocalAuthentication

/// View for managing service capabilities/permissions
struct CapabilityManagementView: View {
    let connectionId: String
    @StateObject private var viewModel: CapabilityManagementViewModel
    @State private var showingRevokeConfirmation = false
    @State private var capabilityToRevoke: ManagedCapability?

    init(connectionId: String) {
        self.connectionId = connectionId
        self._viewModel = StateObject(wrappedValue: CapabilityManagementViewModel(connectionId: connectionId))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                loadingView
            } else {
                capabilityList
            }
        }
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadCapabilities()
        }
        .alert("Revoke Permission", isPresented: $showingRevokeConfirmation) {
            Button("Cancel", role: .cancel) {
                capabilityToRevoke = nil
            }
            Button("Revoke", role: .destructive) {
                if let capability = capabilityToRevoke {
                    Task {
                        await viewModel.revokeCapability(capability)
                    }
                }
                capabilityToRevoke = nil
            }
        } message: {
            if let capability = capabilityToRevoke {
                Text("Revoke \"\(capability.displayName)\" permission from this service? This action will require a contract update.")
            }
        }
        .alert("Error", isPresented: $viewModel.showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading permissions...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Capability List

    private var capabilityList: some View {
        List {
            // Active capabilities
            let active = viewModel.capabilities.filter { $0.isEnabled }
            if !active.isEmpty {
                Section {
                    ForEach(active) { capability in
                        CapabilityRow(
                            capability: capability,
                            isProcessing: viewModel.processingCapabilityId == capability.id
                        ) {
                            capabilityToRevoke = capability
                            showingRevokeConfirmation = true
                        }
                    }
                } header: {
                    Label("Active Permissions", systemImage: "checkmark.circle.fill")
                } footer: {
                    Text("These permissions are currently granted to the service.")
                }
            }

            // Revoked capabilities
            let revoked = viewModel.capabilities.filter { !$0.isEnabled }
            if !revoked.isEmpty {
                Section {
                    ForEach(revoked) { capability in
                        CapabilityRow(
                            capability: capability,
                            isProcessing: viewModel.processingCapabilityId == capability.id
                        ) {
                            // Re-enable would require service to request again
                        }
                        .opacity(0.6)
                    }
                } header: {
                    Label("Revoked Permissions", systemImage: "xmark.circle")
                } footer: {
                    Text("These permissions have been revoked. The service must request them again to regain access.")
                }
            }

            // Info section
            Section {
                infoRow(
                    icon: "shield.lefthalf.filled",
                    title: "Permission Control",
                    description: "You control which data and actions this service can access."
                )

                infoRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Contract Updates",
                    description: "Revoking permissions updates your contract with the service."
                )

                infoRow(
                    icon: "clock.arrow.circlepath",
                    title: "Request Again",
                    description: "Revoked permissions can only be restored if the service requests them again."
                )
            } header: {
                Text("About Permissions")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func infoRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Capability Row

struct CapabilityRow: View {
    let capability: ManagedCapability
    var isProcessing: Bool = false
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: capability.icon)
                .foregroundColor(capability.isEnabled ? capability.category.color : .secondary)
                .font(.title2)
                .frame(width: 32)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(capability.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(capability.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                // Last used
                if let lastUsed = capability.lastUsedAt {
                    Text("Last used: \(lastUsed.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Toggle
            if isProcessing {
                ProgressView()
            } else if capability.isEnabled {
                Toggle("", isOn: .constant(true))
                    .labelsHidden()
                    .tint(.green)
                    .onTapGesture {
                        onToggle()
                    }
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Capability Detail Sheet

struct CapabilityDetailSheet: View {
    let capability: ManagedCapability
    @Binding var isPresented: Bool
    let onRevoke: () -> Void

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Image(systemName: capability.icon)
                            .font(.largeTitle)
                            .foregroundColor(capability.category.color)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(capability.displayName)
                                .font(.headline)

                            Text(capability.category.displayName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Description") {
                    Text(capability.description)
                        .font(.subheadline)
                }

                Section("Usage") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(capability.isEnabled ? "Active" : "Revoked")
                            .foregroundColor(capability.isEnabled ? .green : .red)
                    }

                    if let grantedAt = capability.grantedAt {
                        HStack {
                            Text("Granted")
                            Spacer()
                            Text(grantedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundColor(.secondary)
                        }
                    }

                    if let lastUsed = capability.lastUsedAt {
                        HStack {
                            Text("Last Used")
                            Spacer()
                            Text(lastUsed.formatted(.relative(presentation: .named)))
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Usage Count")
                        Spacer()
                        Text("\(capability.usageCount)")
                            .foregroundColor(.secondary)
                    }
                }

                if capability.isEnabled {
                    Section {
                        Button(role: .destructive) {
                            onRevoke()
                            isPresented = false
                        } label: {
                            HStack {
                                Spacer()
                                Text("Revoke Permission")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Permission Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

// MARK: - Capability Types

/// Managed capability for a service connection
struct ManagedCapability: Codable, Identifiable {
    let id: String
    let type: CapabilityType
    let displayName: String
    let description: String
    var isEnabled: Bool
    let grantedAt: Date?
    var revokedAt: Date?
    let lastUsedAt: Date?
    let usageCount: Int

    var icon: String {
        type.icon
    }

    var category: CapabilityCategory {
        type.category
    }

    enum CodingKeys: String, CodingKey {
        case id = "capability_id"
        case type
        case displayName = "display_name"
        case description
        case isEnabled = "is_enabled"
        case grantedAt = "granted_at"
        case revokedAt = "revoked_at"
        case lastUsedAt = "last_used_at"
        case usageCount = "usage_count"
    }
}

/// Capability types
enum CapabilityType: String, Codable {
    case readProfile = "read_profile"
    case readEmail = "read_email"
    case readPhone = "read_phone"
    case readAddress = "read_address"
    case sendMessages = "send_messages"
    case requestAuth = "request_auth"
    case requestPayment = "request_payment"
    case storeData = "store_data"
    case initiateCall = "initiate_call"

    var icon: String {
        switch self {
        case .readProfile: return "person.fill"
        case .readEmail: return "envelope.fill"
        case .readPhone: return "phone.fill"
        case .readAddress: return "location.fill"
        case .sendMessages: return "message.fill"
        case .requestAuth: return "person.badge.key.fill"
        case .requestPayment: return "creditcard.fill"
        case .storeData: return "externaldrive.fill"
        case .initiateCall: return "phone.arrow.up.right.fill"
        }
    }

    var category: CapabilityCategory {
        switch self {
        case .readProfile, .readEmail, .readPhone, .readAddress:
            return .dataAccess
        case .sendMessages, .initiateCall:
            return .communication
        case .requestAuth:
            return .authentication
        case .requestPayment:
            return .financial
        case .storeData:
            return .storage
        }
    }
}

/// Capability categories
enum CapabilityCategory: String, Codable {
    case dataAccess = "data_access"
    case communication
    case authentication
    case financial
    case storage

    var displayName: String {
        switch self {
        case .dataAccess: return "Data Access"
        case .communication: return "Communication"
        case .authentication: return "Authentication"
        case .financial: return "Financial"
        case .storage: return "Storage"
        }
    }

    var color: Color {
        switch self {
        case .dataAccess: return .blue
        case .communication: return .green
        case .authentication: return .purple
        case .financial: return .orange
        case .storage: return .pink
        }
    }
}

// MARK: - ViewModel

@MainActor
final class CapabilityManagementViewModel: ObservableObject {
    @Published private(set) var capabilities: [ManagedCapability] = []
    @Published private(set) var isLoading = false
    @Published private(set) var processingCapabilityId: String?
    @Published var showingError = false
    @Published var errorMessage: String?

    private let connectionId: String

    init(connectionId: String) {
        self.connectionId = connectionId
    }

    func loadCapabilities() async {
        guard !isLoading else { return }
        isLoading = true

        #if DEBUG
        try? await Task.sleep(nanoseconds: 500_000_000)
        capabilities = mockCapabilities
        #endif

        isLoading = false
    }

    func revokeCapability(_ capability: ManagedCapability) async {
        processingCapabilityId = capability.id

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
                localizedReason: "Authenticate to revoke permission"
            )

            if success {
                // Update local state
                if let index = capabilities.firstIndex(where: { $0.id == capability.id }) {
                    capabilities[index].isEnabled = false
                    capabilities[index].revokedAt = Date()
                }

                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)

                // In production, would send contract update to service
                #if DEBUG
                print("[Capability] Revoked: \(capability.displayName)")
                #endif
            }
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }

        processingCapabilityId = nil
    }

    #if DEBUG
    private var mockCapabilities: [ManagedCapability] {
        [
            ManagedCapability(
                id: "cap-1",
                type: .readEmail,
                displayName: "Read Email",
                description: "Access your email address for account identification and notifications",
                isEnabled: true,
                grantedAt: Date().addingTimeInterval(-86400 * 30),
                revokedAt: nil,
                lastUsedAt: Date().addingTimeInterval(-3600),
                usageCount: 12
            ),
            ManagedCapability(
                id: "cap-2",
                type: .readProfile,
                displayName: "Read Profile",
                description: "Access your display name for personalization",
                isEnabled: true,
                grantedAt: Date().addingTimeInterval(-86400 * 30),
                revokedAt: nil,
                lastUsedAt: Date().addingTimeInterval(-86400),
                usageCount: 5
            ),
            ManagedCapability(
                id: "cap-3",
                type: .sendMessages,
                displayName: "Send Messages",
                description: "Send you notifications and updates",
                isEnabled: true,
                grantedAt: Date().addingTimeInterval(-86400 * 30),
                revokedAt: nil,
                lastUsedAt: Date().addingTimeInterval(-7200),
                usageCount: 28
            ),
            ManagedCapability(
                id: "cap-4",
                type: .requestAuth,
                displayName: "Request Authentication",
                description: "Request login verification for secure access",
                isEnabled: true,
                grantedAt: Date().addingTimeInterval(-86400 * 30),
                revokedAt: nil,
                lastUsedAt: Date().addingTimeInterval(-1800),
                usageCount: 8
            ),
            ManagedCapability(
                id: "cap-5",
                type: .readAddress,
                displayName: "Read Address",
                description: "Access your physical address for shipping",
                isEnabled: false,
                grantedAt: Date().addingTimeInterval(-86400 * 20),
                revokedAt: Date().addingTimeInterval(-86400 * 5),
                lastUsedAt: Date().addingTimeInterval(-86400 * 6),
                usageCount: 2
            )
        ]
    }
    #endif
}

// MARK: - Preview

#if DEBUG
struct CapabilityManagementView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            CapabilityManagementView(connectionId: "test-connection")
        }
    }
}
#endif
