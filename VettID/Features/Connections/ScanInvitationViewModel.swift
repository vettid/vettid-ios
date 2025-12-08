import Foundation

/// State for scan invitation flow
enum ScanInvitationState: Equatable {
    case scanning
    case processing
    case preview(PeerInvitationInfo)
    case success(Connection)
    case error(String)

    static func == (lhs: ScanInvitationState, rhs: ScanInvitationState) -> Bool {
        switch (lhs, rhs) {
        case (.scanning, .scanning), (.processing, .processing):
            return true
        case (.preview(let a), .preview(let b)):
            return a.code == b.code
        case (.success(let a), .success(let b)):
            return a.id == b.id
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Information about the invitation being scanned
struct PeerInvitationInfo: Equatable {
    let code: String
    let creatorDisplayName: String
    let expiresAt: Date?
}

/// ViewModel for scanning and accepting connection invitations
@MainActor
final class ScanInvitationViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: ScanInvitationState = .scanning

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let cryptoManager: ConnectionCryptoManager
    private let authTokenProvider: @Sendable () -> String?

    // MARK: - Private State

    private var scannedCode: String?
    private var generatedKeyPair: (publicKey: Data, privateKey: Data)?

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        cryptoManager: ConnectionCryptoManager = ConnectionCryptoManager(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.apiClient = apiClient
        self.cryptoManager = cryptoManager
        self.authTokenProvider = authTokenProvider
    }

    // MARK: - Scanning

    /// Handle QR code scan result
    func onQrCodeScanned(_ data: String) {
        // Parse the QR code data
        // Expected formats:
        // - vettid://invite/{code}
        // - https://vettid.com/invite/{code}
        // - Just the code itself

        let code = parseInvitationCode(from: data)

        guard !code.isEmpty else {
            state = .error("Invalid QR code format")
            return
        }

        processCode(code)
    }

    /// Handle manual code entry
    func onManualCodeEntered(_ code: String) {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            state = .error("Please enter an invitation code")
            return
        }

        processCode(trimmedCode)
    }

    /// Parse invitation code from various formats
    private func parseInvitationCode(from data: String) -> String {
        // Try deep link format
        if data.hasPrefix("vettid://invite/") {
            return String(data.dropFirst("vettid://invite/".count))
        }

        // Try web URL format
        if let url = URL(string: data),
           url.pathComponents.count >= 2,
           url.pathComponents[url.pathComponents.count - 2] == "invite" {
            return url.lastPathComponent
        }

        // Assume it's just the code
        return data.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Process the scanned/entered code
    private func processCode(_ code: String) {
        scannedCode = code
        state = .processing

        // For now, show preview with just the code
        // In a real implementation, you might fetch invitation details first
        let peerInfo = PeerInvitationInfo(
            code: code,
            creatorDisplayName: "Unknown",  // Would be fetched from API
            expiresAt: nil
        )

        state = .preview(peerInfo)
    }

    // MARK: - Accept Invitation

    /// Accept the scanned invitation
    func acceptInvitation() async {
        guard let code = scannedCode else {
            state = .error("No invitation code")
            return
        }

        guard let authToken = authTokenProvider() else {
            state = .error("Not authenticated")
            return
        }

        state = .processing

        do {
            // Generate key pair for this connection
            let keyPair = try cryptoManager.generateConnectionKeyPair()
            generatedKeyPair = keyPair

            // Accept invitation via API
            let response = try await apiClient.acceptInvitation(
                code: code,
                publicKey: keyPair.publicKey,
                authToken: authToken
            )

            // Derive and store connection key
            if let peerPublicKeyData = Data(base64Encoded: response.peerPublicKey) {
                try await storeConnectionKey(
                    connectionId: response.connection.id,
                    peerPublicKey: peerPublicKeyData
                )
            }

            state = .success(response.connection)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Store the connection key after accepting
    private func storeConnectionKey(connectionId: String, peerPublicKey: Data) async throws {
        guard let keyPair = generatedKeyPair else {
            throw ConnectionError.noKeyPair
        }

        // Derive shared secret
        let sharedSecret = try cryptoManager.deriveSharedSecret(
            privateKey: keyPair.privateKey,
            peerPublicKey: peerPublicKey
        )

        // Derive connection key
        let connectionKey = try cryptoManager.deriveConnectionKey(
            sharedSecret: sharedSecret,
            connectionId: connectionId
        )

        // Store in Keychain
        try cryptoManager.storeConnectionKey(connectionId: connectionId, key: connectionKey)
    }

    // MARK: - Actions

    /// Reset to scanning state
    func reset() {
        state = .scanning
        scannedCode = nil
        generatedKeyPair = nil
    }

    /// Go back to scanning from preview
    func cancelPreview() {
        state = .scanning
        scannedCode = nil
    }
}
