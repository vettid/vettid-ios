import Foundation

/// State for service discovery flow
enum ServiceDiscoveryState: Equatable {
    case idle
    case scanning
    case discovering
    case discovered(ServiceDiscoveryResult)
    case reviewing
    case connecting
    case connected(ServiceConnectionRecord)
    case error(String)

    static func == (lhs: ServiceDiscoveryState, rhs: ServiceDiscoveryState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.scanning, .scanning),
             (.discovering, .discovering),
             (.reviewing, .reviewing),
             (.connecting, .connecting):
            return true
        case (.discovered(let l), .discovered(let r)):
            return l.serviceProfile.id == r.serviceProfile.id
        case (.connected(let l), .connected(let r)):
            return l.id == r.id
        case (.error(let l), .error(let r)):
            return l == r
        default:
            return false
        }
    }
}

/// ViewModel for service discovery flow
@MainActor
final class ServiceDiscoveryViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: ServiceDiscoveryState = .idle
    @Published var manualCode = ""
    @Published var errorMessage: String?
    @Published var showingContractReview = false

    // MARK: - Discovery Result

    @Published private(set) var discoveryResult: ServiceDiscoveryResult?
    @Published var selectedOptionalFields: Set<String> = []

    // MARK: - Dependencies

    private let serviceConnectionHandler: ServiceConnectionHandler
    private let serviceConnectionStore: ServiceConnectionStore

    // MARK: - Initialization

    init(
        serviceConnectionHandler: ServiceConnectionHandler,
        serviceConnectionStore: ServiceConnectionStore = ServiceConnectionStore()
    ) {
        self.serviceConnectionHandler = serviceConnectionHandler
        self.serviceConnectionStore = serviceConnectionStore
    }

    // MARK: - Discovery

    /// Discover service from QR code scan
    func discoverFromQRCode(_ code: String) async {
        await discover(code: code)
    }

    /// Discover service from manual code entry
    func discoverFromManualCode() async {
        let code = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            errorMessage = "Please enter a service code"
            return
        }
        await discover(code: code)
    }

    /// Discover service from universal link
    func discoverFromUniversalLink(_ url: URL) async {
        // Extract code from URL path
        // Expected format: vettid://service/{code} or https://vettid.app/service/{code}
        guard let code = extractServiceCode(from: url) else {
            state = .error("Invalid service link")
            return
        }
        await discover(code: code)
    }

    private func discover(code: String) async {
        state = .discovering

        do {
            let result = try await serviceConnectionHandler.discoverService(code: code)
            discoveryResult = result

            // Pre-select all optional fields
            selectedOptionalFields = Set(result.proposedContract.optionalFields.map { $0.field })

            state = .discovered(result)
        } catch {
            state = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func extractServiceCode(from url: URL) -> String? {
        // Handle vettid://service/{code}
        if url.scheme == "vettid" && url.host == "service" {
            return url.pathComponents.last
        }

        // Handle https://vettid.app/service/{code}
        if url.host?.contains("vettid") == true {
            let components = url.pathComponents
            if let serviceIndex = components.firstIndex(of: "service"),
               serviceIndex + 1 < components.count {
                return components[serviceIndex + 1]
            }
        }

        return nil
    }

    // MARK: - Contract Review

    /// Show contract review screen
    func showContractReview() {
        guard discoveryResult != nil else { return }
        state = .reviewing
        showingContractReview = true
    }

    /// Toggle optional field selection
    func toggleOptionalField(_ fieldId: String) {
        if selectedOptionalFields.contains(fieldId) {
            selectedOptionalFields.remove(fieldId)
        } else {
            selectedOptionalFields.insert(fieldId)
        }
    }

    /// Check if user has all required fields
    var hasMissingRequiredFields: Bool {
        guard let result = discoveryResult else { return false }
        return !result.missingRequiredFields.isEmpty
    }

    /// Get missing required field names
    var missingFieldNames: [String] {
        guard let result = discoveryResult else { return [] }
        return result.missingRequiredFields.map { $0.fieldType.displayLabel }
    }

    // MARK: - Connection

    /// Accept the contract and connect to the service
    func acceptContract() async {
        guard let result = discoveryResult else { return }

        state = .connecting

        do {
            // Build field mappings from required and selected optional fields
            var fieldMappings: [SharedFieldMapping] = []

            // Add required fields
            for field in result.proposedContract.requiredFields {
                fieldMappings.append(SharedFieldMapping(
                    fieldSpec: field,
                    localFieldKey: field.field,
                    sharedAt: Date(),
                    lastUpdatedAt: nil
                ))
            }

            // Add selected optional fields
            for field in result.proposedContract.optionalFields {
                if selectedOptionalFields.contains(field.field) {
                    fieldMappings.append(SharedFieldMapping(
                        fieldSpec: field,
                        localFieldKey: field.field,
                        sharedAt: Date(),
                        lastUpdatedAt: nil
                    ))
                }
            }

            // Initiate connection
            let connection = try await serviceConnectionHandler.initiateConnection(
                serviceId: result.serviceProfile.id,
                contractId: result.proposedContract.id,
                fieldMappings: fieldMappings
            )

            // Store locally
            try serviceConnectionStore.store(connection: connection)

            // Cache service profile for offline viewing
            try serviceConnectionStore.cacheServiceProfile(result.serviceProfile)

            state = .connected(connection)
            showingContractReview = false
        } catch {
            state = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Decline the contract
    func declineContract() {
        reset()
    }

    // MARK: - State Management

    /// Start QR code scanning
    func startScanning() {
        state = .scanning
    }

    /// Cancel scanning
    func cancelScanning() {
        state = .idle
    }

    /// Reset to initial state
    func reset() {
        state = .idle
        discoveryResult = nil
        selectedOptionalFields = []
        manualCode = ""
        errorMessage = nil
        showingContractReview = false
    }

    /// Clear error
    func clearError() {
        errorMessage = nil
        if case .error = state {
            state = .idle
        }
    }
}
