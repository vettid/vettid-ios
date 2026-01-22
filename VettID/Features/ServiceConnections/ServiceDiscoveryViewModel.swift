import Foundation
import LocalAuthentication

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
    private let contractStore: ContractStore

    // MARK: - Signing State

    @Published var showingBiometricPrompt = false
    @Published var signingError: String?
    private var pendingSignRequest: (request: ContractSignRequest, privateKey: Data)?

    // MARK: - Initialization

    init(
        serviceConnectionHandler: ServiceConnectionHandler,
        serviceConnectionStore: ServiceConnectionStore = ServiceConnectionStore(),
        contractStore: ContractStore = ContractStore()
    ) {
        self.serviceConnectionHandler = serviceConnectionHandler
        self.serviceConnectionStore = serviceConnectionStore
        self.contractStore = contractStore
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
    /// This triggers biometric authentication before signing
    func acceptContract() async {
        guard let result = discoveryResult else { return }

        // Build field mappings from required and selected optional fields
        let fieldMappings = buildFieldMappings(from: result)

        // Create contract sign request with new connection keypair
        do {
            let (signRequest, privateKey) = try ServiceMessageCrypto.createContractSignRequest(
                serviceId: result.serviceProfile.id,
                offeringId: result.proposedContract.id,
                offeringSnapshot: result.proposedContract,
                selectedFields: fieldMappings
            )

            // Store pending request for after biometric auth
            pendingSignRequest = (signRequest, privateKey)

            // Request biometric authentication
            await requestBiometricAuth()

        } catch {
            state = .error("Failed to create sign request: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Build field mappings from discovery result and selected optional fields
    private func buildFieldMappings(from result: ServiceDiscoveryResult) -> [SharedFieldMapping] {
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

        return fieldMappings
    }

    /// Request biometric authentication before signing
    private func requestBiometricAuth() async {
        let context = LAContext()
        var authError: NSError?

        // Check if biometrics are available
        let canUseBiometrics = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &authError
        )

        let policy: LAPolicy = canUseBiometrics ?
            .deviceOwnerAuthenticationWithBiometrics :
            .deviceOwnerAuthentication

        let reason = "Authenticate to sign the service contract"

        do {
            let success = try await context.evaluatePolicy(policy, localizedReason: reason)

            if success {
                await completeContractSigning()
            } else {
                signingError = "Authentication failed"
                state = .error("Authentication failed")
            }
        } catch let error as LAError {
            switch error.code {
            case .userCancel:
                signingError = "Authentication cancelled"
                // Stay on reviewing state
                if case .connecting = state {
                    state = .reviewing
                }
            case .userFallback:
                // User chose to enter passcode
                await requestPasscodeAuth()
            default:
                signingError = error.localizedDescription
                state = .error(error.localizedDescription)
            }
        } catch {
            signingError = error.localizedDescription
            state = .error(error.localizedDescription)
        }
    }

    /// Request passcode authentication as fallback
    private func requestPasscodeAuth() async {
        let context = LAContext()

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Enter your passcode to sign the service contract"
            )

            if success {
                await completeContractSigning()
            } else {
                signingError = "Authentication failed"
                state = .error("Authentication failed")
            }
        } catch {
            signingError = error.localizedDescription
            state = .error(error.localizedDescription)
        }
    }

    /// Complete contract signing after successful authentication
    private func completeContractSigning() async {
        guard let result = discoveryResult,
              let pending = pendingSignRequest else {
            state = .error("No pending sign request")
            return
        }

        state = .connecting
        signingError = nil

        do {
            // Send sign request to vault via NATS
            let signResponse = try await sendContractSignRequest(pending.request)

            guard signResponse.success, let signResult = signResponse.result else {
                throw ContractSigningError.signingFailed(signResponse.error ?? "Unknown error")
            }

            // Store the signed contract and keys
            let storedContract = StoredContract(
                contractId: signResult.contractId,
                serviceId: result.serviceProfile.id,
                serviceName: result.serviceProfile.serviceName,
                serviceLogoUrl: result.serviceProfile.serviceLogoUrl,
                offeringId: result.proposedContract.id,
                offeringSnapshot: result.proposedContract,
                capabilities: buildCapabilities(from: result.proposedContract),
                sharedFields: buildFieldMappings(from: result),
                userConnectionKeyId: signResult.contractId, // Use contract ID as key reference
                serviceConnectionKey: signResult.serviceConnectionKey,
                serviceSigningKey: signResult.serviceSigningKey,
                userSignature: signResult.signedContract.userSignature,
                serviceSignature: signResult.signedContract.serviceSignature,
                status: .active,
                createdAt: Date(),
                activatedAt: signResult.signedContract.activatedAt,
                revokedAt: nil
            )

            // Store contract with keys
            try contractStore.store(
                contract: storedContract,
                connectionPrivateKey: pending.privateKey,
                natsCredentials: signResult.natsCredentials
            )

            // Also create legacy ServiceConnectionRecord for UI compatibility
            let connection = ServiceConnectionRecord(
                id: signResult.contractId,
                serviceGuid: result.serviceProfile.id,
                serviceProfile: result.serviceProfile,
                contractId: signResult.contractId,
                contractVersion: result.proposedContract.version,
                contractAcceptedAt: Date(),
                pendingContractVersion: nil,
                status: .active,
                sharedFields: buildFieldMappings(from: result),
                createdAt: Date(),
                lastActivityAt: nil,
                tags: [],
                isFavorite: false,
                isArchived: false,
                isMuted: false
            )

            // Store in service connection store for UI
            try serviceConnectionStore.store(connection: connection)

            // Cache service profile
            try serviceConnectionStore.cacheServiceProfile(result.serviceProfile)

            // Clear pending request
            pendingSignRequest = nil

            state = .connected(connection)
            showingContractReview = false

        } catch {
            pendingSignRequest = nil
            state = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Send contract sign request to vault via service connection handler
    private func sendContractSignRequest(_ request: ContractSignRequest) async throws -> ContractSignResponse {
        // Use service connection handler to sign the contract
        // The handler routes this through NATS internally
        return try await serviceConnectionHandler.signContract(request: request)
    }

    /// Build capabilities list from contract
    private func buildCapabilities(from contract: ServiceDataContract) -> [String] {
        var capabilities: [String] = []
        if contract.canStoreData { capabilities.append("store_data") }
        if contract.canSendMessages { capabilities.append("send_messages") }
        if contract.canRequestAuth { capabilities.append("request_auth") }
        if contract.canRequestPayment { capabilities.append("request_payment") }
        return capabilities
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

// MARK: - Contract Signing Error

enum ContractSigningError: Error, LocalizedError {
    case signingFailed(String)
    case noPendingRequest
    case authenticationFailed
    case authenticationCancelled

    var errorDescription: String? {
        switch self {
        case .signingFailed(let reason):
            return "Contract signing failed: \(reason)"
        case .noPendingRequest:
            return "No pending sign request found"
        case .authenticationFailed:
            return "Authentication failed"
        case .authenticationCancelled:
            return "Authentication was cancelled"
        }
    }
}
