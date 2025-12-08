import Foundation

/// State for create invitation flow
enum CreateInvitationState: Equatable {
    case idle
    case creating
    case created(ConnectionInvitation)
    case error(String)

    static func == (lhs: CreateInvitationState, rhs: CreateInvitationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.creating, .creating):
            return true
        case (.created(let a), .created(let b)):
            return a.invitationId == b.invitationId
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// ViewModel for creating connection invitations
@MainActor
final class CreateInvitationViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: CreateInvitationState = .idle
    @Published var expirationMinutes: Int = 60

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let cryptoManager: ConnectionCryptoManager
    private let authTokenProvider: @Sendable () -> String?

    // MARK: - Private State

    private var generatedKeyPair: (publicKey: Data, privateKey: Data)?
    private var currentInvitation: ConnectionInvitation?

    // MARK: - Expiration Options

    static let expirationOptions = [
        (minutes: 15, label: "15 minutes"),
        (minutes: 30, label: "30 minutes"),
        (minutes: 60, label: "1 hour"),
        (minutes: 1440, label: "24 hours")
    ]

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

    // MARK: - Actions

    /// Create a new connection invitation
    func createInvitation() async {
        guard let authToken = authTokenProvider() else {
            state = .error("Not authenticated")
            return
        }

        state = .creating

        do {
            // Generate key pair for this invitation
            let keyPair = try cryptoManager.generateConnectionKeyPair()
            generatedKeyPair = keyPair

            // Create invitation via API
            let invitation = try await apiClient.createInvitation(
                expiresInMinutes: expirationMinutes,
                publicKey: keyPair.publicKey,
                authToken: authToken
            )

            currentInvitation = invitation
            state = .created(invitation)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Reset to idle state
    func reset() {
        state = .idle
        generatedKeyPair = nil
        currentInvitation = nil
    }

    /// Get the invitation deep link URL
    var deepLinkUrl: String? {
        if case .created(let invitation) = state {
            return invitation.deepLinkUrl
        }
        return nil
    }

    /// Get the invitation code for manual entry
    var invitationCode: String? {
        if case .created(let invitation) = state {
            return invitation.invitationCode
        }
        return nil
    }

    /// Get the QR code data
    var qrCodeData: String? {
        if case .created(let invitation) = state {
            return invitation.qrCodeData
        }
        return nil
    }

    /// Time remaining until expiration
    func timeRemaining() -> TimeInterval? {
        if case .created(let invitation) = state {
            return invitation.expiresAt.timeIntervalSinceNow
        }
        return nil
    }

    /// Whether the invitation has expired
    var isExpired: Bool {
        guard let remaining = timeRemaining() else { return false }
        return remaining <= 0
    }

    /// Store the connection key after peer accepts
    func storeConnectionKey(connectionId: String, peerPublicKey: Data) async throws {
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
}

// MARK: - Errors

enum ConnectionError: Error, LocalizedError {
    case noKeyPair
    case invalidInvitationCode
    case invitationExpired

    var errorDescription: String? {
        switch self {
        case .noKeyPair:
            return "No key pair available"
        case .invalidInvitationCode:
            return "Invalid invitation code"
        case .invitationExpired:
            return "This invitation has expired"
        }
    }
}
