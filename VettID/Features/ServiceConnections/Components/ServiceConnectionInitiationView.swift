import SwiftUI
import AVFoundation

/// View for initiating service connections via QR code, deep link, or directory
/// (Issue #11: Service connection initiation screen)
struct ServiceConnectionInitiationView: View {
    @StateObject private var viewModel = ServiceConnectionInitiationViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .scanning:
                    scannerView

                case .loading:
                    loadingView

                case .loaded(let serviceInfo):
                    servicePreviewView(serviceInfo)

                case .error(let message):
                    errorView(message)
                }
            }
            .navigationTitle("Connect to Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $viewModel.showingContractReview) {
                if let serviceInfo = viewModel.serviceInfo {
                    ContractSigningView(
                        serviceInfo: serviceInfo,
                        offerings: viewModel.offerings,
                        onConnect: { selectedOffering, optionalFields in
                            Task {
                                await viewModel.initiateConnection(
                                    offering: selectedOffering,
                                    optionalFields: optionalFields
                                )
                                dismiss()
                            }
                        },
                        onCancel: {
                            viewModel.showingContractReview = false
                        }
                    )
                }
            }
        }
    }

    // MARK: - Scanner View

    private var scannerView: some View {
        ZStack {
            // Camera preview
            QRCodeScannerView(
                onScan: { code in
                    Task {
                        await viewModel.handleScannedCode(code)
                    }
                },
                onError: { error in
                    viewModel.handleScanError(error)
                }
            )
            .ignoresSafeArea()

            // Overlay
            ScanOverlayView()

            // Manual entry option
            VStack {
                Spacer()

                Button {
                    viewModel.showManualEntry = true
                } label: {
                    Label("Enter Code Manually", systemImage: "keyboard")
                        .font(.subheadline)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }
                .padding(.bottom, 100)
            }
        }
        .sheet(isPresented: $viewModel.showManualEntry) {
            ManualCodeEntrySheet(
                onSubmit: { code in
                    Task {
                        await viewModel.handleScannedCode(code)
                    }
                },
                onCancel: {
                    viewModel.showManualEntry = false
                }
            )
            .presentationDetents([.medium])
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Fetching service information...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Service Preview View

    private func servicePreviewView(_ serviceInfo: ServiceConnectionInfo) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // Service header
                serviceHeader(serviceInfo)

                // Verification badge
                if serviceInfo.domainVerified {
                    verificationBadge
                }

                // Description
                if let description = serviceInfo.description {
                    descriptionSection(description)
                }

                // Available offerings
                if !viewModel.offerings.isEmpty {
                    offeringsSection
                }

                // Connect button
                connectButton
            }
            .padding()
        }
    }

    private func serviceHeader(_ serviceInfo: ServiceConnectionInfo) -> some View {
        VStack(spacing: 16) {
            // Logo
            if let logoUrl = serviceInfo.logoUrl, let url = URL(string: logoUrl) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    servicePlaceholder
                }
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                servicePlaceholder
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            // Name
            HStack {
                Text(serviceInfo.name)
                    .font(.title2)
                    .fontWeight(.bold)

                if serviceInfo.domainVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.blue)
                }
            }

            // Domain
            if let domain = serviceInfo.domain {
                Text(domain)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var servicePlaceholder: some View {
        ZStack {
            Color(UIColor.tertiarySystemBackground)
            Image(systemName: "building.2.fill")
                .font(.title)
                .foregroundColor(.secondary)
        }
    }

    private var verificationBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Verified Service")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Domain ownership has been verified")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(12)
    }

    private func descriptionSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.headline)

            Text(description)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var offeringsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Plans")
                .font(.headline)

            ForEach(viewModel.offerings) { offering in
                OfferingCard(
                    offering: offering,
                    isSelected: viewModel.selectedOffering?.id == offering.id
                ) {
                    viewModel.selectedOffering = offering
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectButton: some View {
        VStack(spacing: 12) {
            Button {
                viewModel.showingContractReview = true
            } label: {
                HStack {
                    Image(systemName: "link")
                    Text("Review & Connect")
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

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Unable to Connect")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") {
                viewModel.reset()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Offering Card

struct OfferingCard: View {
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

                    if let price = offering.price {
                        Text(price)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                    }
                }

                Spacer()

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

// MARK: - Manual Code Entry Sheet

struct ManualCodeEntrySheet: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var code = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Enter the service connection code")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField("Connection code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isFocused)

                Button("Connect") {
                    onSubmit(code)
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.isEmpty)

                Spacer()
            }
            .padding()
            .navigationTitle("Manual Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .onAppear {
                isFocused = true
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class ServiceConnectionInitiationViewModel: ObservableObject {
    enum State {
        case scanning
        case loading
        case loaded(ServiceConnectionInfo)
        case error(String)
    }

    @Published private(set) var state: State = .scanning
    @Published private(set) var serviceInfo: ServiceConnectionInfo?
    @Published private(set) var offerings: [ContractOffering] = []
    @Published var selectedOffering: ContractOffering?
    @Published var showManualEntry = false
    @Published var showingContractReview = false

    private var connectionData: ServiceConnectionData?

    func handleScannedCode(_ code: String) async {
        // Parse the connection URL/code
        guard let data = parseConnectionCode(code) else {
            state = .error("Invalid connection code. Please try again.")
            return
        }

        connectionData = data
        state = .loading

        do {
            // Fetch service info
            let info = try await fetchServiceInfo(data)
            serviceInfo = info

            // Fetch offerings
            offerings = try await fetchOfferings(data)
            if let first = offerings.first {
                selectedOffering = first
            }

            state = .loaded(info)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func handleScanError(_ error: Error) {
        state = .error(error.localizedDescription)
    }

    func reset() {
        state = .scanning
        serviceInfo = nil
        offerings = []
        selectedOffering = nil
        connectionData = nil
    }

    func initiateConnection(offering: ContractOffering, optionalFields: Set<String>) async {
        // In production, this would send the connection request to the vault
        #if DEBUG
        print("[ServiceConnection] Initiating connection with offering: \(offering.name)")
        print("[ServiceConnection] Optional fields: \(optionalFields)")
        #endif
    }

    // MARK: - Private Methods

    private func parseConnectionCode(_ code: String) -> ServiceConnectionData? {
        // Handle vettid:// URL scheme
        if code.starts(with: "vettid://connect") {
            guard let url = URL(string: code),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return nil
            }

            let queryItems = components.queryItems ?? []
            let serviceId = queryItems.first(where: { $0.name == "service_id" })?.value
            let natsEndpoint = queryItems.first(where: { $0.name == "nats" })?.value
            let inviteId = queryItems.first(where: { $0.name == "invite" })?.value

            guard let serviceId = serviceId else { return nil }

            return ServiceConnectionData(
                serviceId: serviceId,
                natsEndpoint: natsEndpoint,
                inviteId: inviteId
            )
        }

        // Handle plain service ID
        if code.count > 8 && !code.contains(" ") {
            return ServiceConnectionData(
                serviceId: code,
                natsEndpoint: nil,
                inviteId: nil
            )
        }

        return nil
    }

    private func fetchServiceInfo(_ data: ServiceConnectionData) async throws -> ServiceConnectionInfo {
        // In production, fetch from directory or NATS
        #if DEBUG
        try await Task.sleep(nanoseconds: 500_000_000)

        return ServiceConnectionInfo(
            id: data.serviceId,
            name: "Example Service",
            description: "A sample service for demonstrating the connection flow.",
            logoUrl: nil,
            domain: "example.com",
            domainVerified: true,
            category: .technology
        )
        #else
        throw NSError(domain: "ServiceConnection", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not implemented"])
        #endif
    }

    private func fetchOfferings(_ data: ServiceConnectionData) async throws -> [ContractOffering] {
        #if DEBUG
        return [
            ContractOffering(
                id: "basic",
                name: "Basic",
                description: "Essential features for getting started",
                price: "Free",
                requiredFields: ["email", "display_name"],
                optionalFields: ["phone"],
                capabilities: ["read_email", "send_messages"]
            ),
            ContractOffering(
                id: "premium",
                name: "Premium",
                description: "Full access with all features",
                price: "$9.99/month",
                requiredFields: ["email", "display_name", "phone"],
                optionalFields: ["address"],
                capabilities: ["read_email", "read_phone", "send_messages", "request_auth"]
            )
        ]
        #else
        return []
        #endif
    }
}

// MARK: - Types

struct ServiceConnectionData {
    let serviceId: String
    let natsEndpoint: String?
    let inviteId: String?
}

struct ServiceConnectionInfo: Identifiable {
    let id: String
    let name: String
    let description: String?
    let logoUrl: String?
    let domain: String?
    let domainVerified: Bool
    let category: ServiceCategory
}

struct ContractOffering: Identifiable {
    let id: String
    let name: String
    let description: String?
    let price: String?
    let requiredFields: [String]
    let optionalFields: [String]
    let capabilities: [String]  // Capability type raw values
}

// MARK: - Deep Link Handler

/// Handles vettid:// deep links for service connections
struct ServiceConnectionDeepLinkHandler {
    static func canHandle(_ url: URL) -> Bool {
        url.scheme == "vettid" && url.host == "connect"
    }

    static func parse(_ url: URL) -> ServiceConnectionData? {
        guard canHandle(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        guard let serviceId = queryItems.first(where: { $0.name == "service_id" })?.value else {
            return nil
        }

        return ServiceConnectionData(
            serviceId: serviceId,
            natsEndpoint: queryItems.first(where: { $0.name == "nats" })?.value,
            inviteId: queryItems.first(where: { $0.name == "invite" })?.value
        )
    }
}

// MARK: - Preview

#if DEBUG
struct ServiceConnectionInitiationView_Previews: PreviewProvider {
    static var previews: some View {
        ServiceConnectionInitiationView()
    }
}
#endif
