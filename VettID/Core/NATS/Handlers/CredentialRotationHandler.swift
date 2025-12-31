import Foundation
import os.log

/// Handler for vault-initiated credential rotation via NATS
///
/// Subscribes to `forApp.credentials.rotate` topic and handles:
/// - New LAT (Ledger Auth Token) from vault
/// - New NATS credentials
/// - New UTKs (Use Transaction Keys)
///
/// The vault proactively pushes credential rotations when:
/// - Credentials are approaching expiration
/// - Security policy requires rotation
/// - User requests credential refresh
actor CredentialRotationHandler {

    // MARK: - Logging

    private static let logger = Logger(subsystem: "dev.vettid", category: "CredentialRotation")

    // MARK: - Dependencies

    private let ownerSpaceClient: OwnerSpaceClient
    private let credentialStore: CredentialStore
    private let natsCredentialStore: NatsCredentialStore

    // MARK: - State

    private var subscriptionTask: Task<Void, Never>?
    private var isListening: Bool = false

    // MARK: - Initialization

    init(
        ownerSpaceClient: OwnerSpaceClient,
        credentialStore: CredentialStore = CredentialStore(),
        natsCredentialStore: NatsCredentialStore = NatsCredentialStore()
    ) {
        self.ownerSpaceClient = ownerSpaceClient
        self.credentialStore = credentialStore
        self.natsCredentialStore = natsCredentialStore
    }

    // MARK: - Subscription Management

    /// Start listening for credential rotation messages
    func startListening() async {
        guard !isListening else {
            Self.logger.debug("Already listening for credential rotations")
            return
        }

        isListening = true
        Self.logger.info("Starting credential rotation listener")

        subscriptionTask = Task { [weak self] in
            await self?.listenForRotations()
        }
    }

    /// Stop listening for credential rotation messages
    func stopListening() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        isListening = false
        Self.logger.info("Stopped credential rotation listener")
    }

    /// Listen for rotation messages from vault
    private func listenForRotations() async {
        do {
            let stream = try await ownerSpaceClient.subscribeToVault(
                topic: "credentials.rotate",
                type: CredentialRotationMessage.self
            )

            Self.logger.info("Subscribed to forApp.credentials.rotate")

            for await message in stream {
                if Task.isCancelled { break }

                Self.logger.info("Received credential rotation: rotationType=\(message.rotationType, privacy: .public)")
                await handleRotation(message)
            }
        } catch {
            Self.logger.error("Failed to subscribe to credential rotation: \(error.localizedDescription, privacy: .public)")
        }

        isListening = false
    }

    // MARK: - Rotation Handling

    /// Handle an incoming credential rotation message
    private func handleRotation(_ message: CredentialRotationMessage) async {
        do {
            switch message.rotationType {
            case "full":
                try await handleFullRotation(message)
            case "lat":
                try await handleLatRotation(message)
            case "nats":
                try await handleNatsRotation(message)
            case "utk":
                try await handleUtkReplenishment(message)
            default:
                Self.logger.warning("Unknown rotation type: \(message.rotationType, privacy: .public)")
            }

            // Post success notification
            await postNotification(.credentialRotationCompleted, userInfo: [
                "rotationType": message.rotationType,
                "timestamp": message.timestamp ?? ISO8601DateFormatter().string(from: Date())
            ])

        } catch {
            Self.logger.error("Failed to handle credential rotation: \(error.localizedDescription, privacy: .public)")

            // Post failure notification
            await postNotification(.credentialRotationFailed, userInfo: [
                "rotationType": message.rotationType,
                "error": error.localizedDescription
            ])
        }
    }

    /// Handle full credential rotation (LAT + NATS + UTKs)
    private func handleFullRotation(_ message: CredentialRotationMessage) async throws {
        Self.logger.info("Processing full credential rotation")

        // Update LAT if provided
        if let lat = message.lat {
            try await updateStoredLat(lat, userGuid: message.userGuid)
        }

        // Update NATS credentials if provided
        if let natsCreds = message.natsCredentials {
            try await updateNatsCredentials(natsCreds)
        }

        // Add new UTKs if provided
        if let utks = message.transactionKeys, !utks.isEmpty {
            try await addTransactionKeys(utks, userGuid: message.userGuid)
        }

        Self.logger.info("Full credential rotation complete")
    }

    /// Handle LAT-only rotation
    private func handleLatRotation(_ message: CredentialRotationMessage) async throws {
        guard let lat = message.lat else {
            throw CredentialRotationError.missingLatData
        }

        Self.logger.info("Processing LAT rotation")
        try await updateStoredLat(lat, userGuid: message.userGuid)
        Self.logger.info("LAT rotation complete")
    }

    /// Handle NATS credentials rotation
    private func handleNatsRotation(_ message: CredentialRotationMessage) async throws {
        guard let natsCreds = message.natsCredentials else {
            throw CredentialRotationError.missingNatsCredentials
        }

        Self.logger.info("Processing NATS credential rotation")
        try await updateNatsCredentials(natsCreds)
        Self.logger.info("NATS credential rotation complete")
    }

    /// Handle UTK replenishment
    private func handleUtkReplenishment(_ message: CredentialRotationMessage) async throws {
        guard let utks = message.transactionKeys, !utks.isEmpty else {
            throw CredentialRotationError.missingTransactionKeys
        }

        Self.logger.info("Processing UTK replenishment: \(utks.count, privacy: .public) keys")
        try await addTransactionKeys(utks, userGuid: message.userGuid)
        Self.logger.info("UTK replenishment complete")
    }

    // MARK: - Storage Updates

    /// Update stored LAT
    private func updateStoredLat(_ lat: RotationLat, userGuid: String?) async throws {
        // Retrieve existing credential
        guard let credential = try credentialStore.retrieveFirst() else {
            throw CredentialRotationError.noStoredCredential
        }

        // Verify user GUID matches if provided
        if let rotationUserGuid = userGuid, rotationUserGuid != credential.userGuid {
            Self.logger.warning("User GUID mismatch in rotation message")
            throw CredentialRotationError.userGuidMismatch
        }

        // Update LAT (latId falls back to token if not provided)
        let newLat = StoredLAT(
            latId: lat.latId ?? lat.token,
            token: lat.token,
            version: lat.version ?? 1
        )

        let updatedCredential = StoredCredential(
            userGuid: credential.userGuid,
            encryptedBlob: credential.encryptedBlob,
            cekVersion: credential.cekVersion,
            ledgerAuthToken: newLat,
            transactionKeys: credential.transactionKeys,
            createdAt: credential.createdAt,
            lastUsedAt: Date(),
            vaultStatus: credential.vaultStatus
        )

        try credentialStore.store(credential: updatedCredential)
        Self.logger.debug("Updated LAT: version=\(lat.version ?? 0, privacy: .public)")
    }

    /// Update NATS credentials
    private func updateNatsCredentials(_ creds: RotationNatsCredentials) async throws {
        // Get current credentials to preserve endpoint and permissions
        let existingCreds = try natsCredentialStore.getCredentials()

        let endpoint = creds.endpoint ?? existingCreds?.endpoint ?? ""
        let ownerSpace = existingCreds?.ownerSpace ?? ""

        // Parse new credentials
        if let credsContent = creds.credentials {
            // Full .creds file content
            guard let newCreds = NatsCredentials(
                fromCredsFileContent: credsContent,
                endpoint: endpoint,
                ownerSpace: ownerSpace,
                messageSpace: nil,
                topics: nil
            ) else {
                throw CredentialRotationError.invalidNatsCredentials
            }

            try natsCredentialStore.saveCredentials(newCreds)
        } else if let jwt = creds.jwt, let seed = creds.seed {
            // Individual JWT and seed
            let expiresAt = creds.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date().addingTimeInterval(86400)

            let newCreds = NatsCredentials(
                tokenId: creds.tokenId ?? UUID().uuidString,
                jwt: jwt,
                seed: seed,
                endpoint: endpoint,
                expiresAt: expiresAt,
                permissions: existingCreds?.permissions ?? NatsPermissions(publish: [], subscribe: [])
            )

            try natsCredentialStore.saveCredentials(newCreds)
        } else {
            throw CredentialRotationError.invalidNatsCredentials
        }

        Self.logger.debug("Updated NATS credentials")
    }

    /// Add new transaction keys
    private func addTransactionKeys(_ utks: [RotationTransactionKey], userGuid: String?) async throws {
        guard let credential = try credentialStore.retrieveFirst() else {
            throw CredentialRotationError.noStoredCredential
        }

        // Verify user GUID matches if provided
        if let rotationUserGuid = userGuid, rotationUserGuid != credential.userGuid {
            throw CredentialRotationError.userGuidMismatch
        }

        // Convert incoming UTKs to StoredUTK format and append to existing keys
        let newKeys = utks.map { utk in
            StoredUTK(
                keyId: utk.keyId,
                publicKey: utk.publicKey,
                algorithm: utk.algorithm,
                isUsed: false
            )
        }

        var updatedKeys = credential.transactionKeys
        updatedKeys.append(contentsOf: newKeys)

        let updatedCredential = StoredCredential(
            userGuid: credential.userGuid,
            encryptedBlob: credential.encryptedBlob,
            cekVersion: credential.cekVersion,
            ledgerAuthToken: credential.ledgerAuthToken,
            transactionKeys: updatedKeys,
            createdAt: credential.createdAt,
            lastUsedAt: Date(),
            vaultStatus: credential.vaultStatus
        )

        try credentialStore.store(credential: updatedCredential)
        Self.logger.debug("Added \(utks.count, privacy: .public) UTKs, new total: \(updatedCredential.unusedKeyCount, privacy: .public)")
    }

    // MARK: - Notifications

    private func postNotification(_ name: Notification.Name, userInfo: [String: Any]) async {
        await MainActor.run {
            NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
        }
    }
}

// MARK: - Message Types

/// Incoming credential rotation message from vault
struct CredentialRotationMessage: Decodable {
    /// Type of rotation: "full", "lat", "nats", "utk"
    let rotationType: String

    /// User GUID (for verification)
    let userGuid: String?

    /// New LAT data
    let lat: RotationLat?

    /// New NATS credentials
    let natsCredentials: RotationNatsCredentials?

    /// New transaction keys
    let transactionKeys: [RotationTransactionKey]?

    /// ISO 8601 timestamp
    let timestamp: String?

    /// Reason for rotation
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case rotationType = "rotation_type"
        case userGuid = "user_guid"
        case lat
        case natsCredentials = "nats_credentials"
        case transactionKeys = "transaction_keys"
        case timestamp
        case reason
    }
}

/// LAT data in rotation message
struct RotationLat: Decodable {
    let token: String
    let latId: String?
    let version: Int?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case token
        case latId = "lat_id"
        case version
        case expiresAt = "expires_at"
    }
}

/// NATS credentials in rotation message
struct RotationNatsCredentials: Decodable {
    /// Full .creds file content (preferred)
    let credentials: String?

    /// Or individual components
    let jwt: String?
    let seed: String?
    let tokenId: String?
    let endpoint: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case credentials
        case jwt
        case seed
        case tokenId = "token_id"
        case endpoint
        case expiresAt = "expires_at"
    }
}

/// Transaction key in rotation message
struct RotationTransactionKey: Decodable {
    let keyId: String
    let publicKey: String
    let algorithm: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case publicKey = "public_key"
        case algorithm
    }
}

// MARK: - Errors

enum CredentialRotationError: LocalizedError {
    case noStoredCredential
    case userGuidMismatch
    case missingLatData
    case missingNatsCredentials
    case missingTransactionKeys
    case invalidNatsCredentials

    var errorDescription: String? {
        switch self {
        case .noStoredCredential:
            return "No stored credential to update"
        case .userGuidMismatch:
            return "User GUID mismatch in rotation message"
        case .missingLatData:
            return "LAT data missing in rotation message"
        case .missingNatsCredentials:
            return "NATS credentials missing in rotation message"
        case .missingTransactionKeys:
            return "Transaction keys missing in rotation message"
        case .invalidNatsCredentials:
            return "Invalid NATS credentials format"
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let credentialRotationCompleted = Notification.Name("dev.vettid.credentialRotationCompleted")
    static let credentialRotationFailed = Notification.Name("dev.vettid.credentialRotationFailed")
}
