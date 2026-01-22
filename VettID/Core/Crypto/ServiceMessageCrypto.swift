import Foundation
import CryptoKit

#if canImport(Sodium)
import Sodium
#endif

/// Cryptographic operations for service connection messages
/// Uses X25519 key exchange + XChaCha20-Poly1305 for encryption
/// and Ed25519 for message signing
///
/// Message format:
/// - Encrypted envelope contains: ephemeral_pubkey (32) || nonce (24) || ciphertext || tag (16)
/// - Signatures cover: event_id || ciphertext
final class ServiceMessageCrypto {

    // MARK: - Crypto Domain

    /// Domain separation for service message encryption
    private static let serviceMessageDomain = "vettid-service-message-v1"

    // MARK: - Keypair Generation

    /// Generate a new X25519 keypair for a service connection
    /// The private key should be stored securely in Keychain
    /// - Returns: Tuple of (privateKey, publicKey) as raw Data
    static func generateConnectionKeypair() throws -> (privateKey: Data, publicKey: Data) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return (privateKey.rawRepresentation, privateKey.publicKey.rawRepresentation)
    }

    // MARK: - Message Encryption

    /// Encrypt a message for a service
    /// - Parameters:
    ///   - payload: The plaintext message payload
    ///   - recipientPublicKey: Service's X25519 public key (32 bytes)
    ///   - signingKey: User's Ed25519 private key for signing
    /// - Returns: Encrypted message with signature
    static func encrypt(
        payload: Data,
        recipientPublicKey: Data,
        signingKey: Data
    ) throws -> ServiceEncryptedMessage {
        // Generate event ID
        let eventId = UUID().uuidString

        // Generate ephemeral X25519 keypair
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeral.publicKey

        // Reconstruct recipient public key
        let recipientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)

        // ECDH to get shared secret
        let sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: recipientKey)

        // HKDF to derive encryption key with domain separation
        let encryptionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: serviceMessageDomain.data(using: .utf8)!,
            sharedInfo: Data(),
            outputByteCount: 32
        )

        // XChaCha20-Poly1305 encrypt
        let (ciphertextWithTag, nonce) = try CryptoManager.encryptXChaCha20Poly1305(
            plaintext: payload,
            key: encryptionKey
        )

        // Sign (event_id || ciphertext)
        let signingData = eventId.data(using: .utf8)! + ciphertextWithTag
        let ed25519Key = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey)
        let signature = try ed25519Key.signature(for: signingData)

        return ServiceEncryptedMessage(
            eventId: eventId,
            ephemeralPublicKey: ephemeralPublic.rawRepresentation,
            nonce: nonce,
            ciphertext: ciphertextWithTag,
            signature: signature
        )
    }

    /// Decrypt a message from a service
    /// - Parameters:
    ///   - message: The encrypted message
    ///   - recipientPrivateKey: User's X25519 private key (32 bytes)
    ///   - senderPublicKey: Service's Ed25519 public key for signature verification
    /// - Returns: Decrypted payload
    static func decrypt(
        message: ServiceEncryptedMessage,
        recipientPrivateKey: Data,
        senderPublicKey: Data
    ) throws -> Data {
        // Verify signature first
        let signingData = message.eventId.data(using: .utf8)! + message.ciphertext
        let senderKey = try Curve25519.Signing.PublicKey(rawRepresentation: senderPublicKey)

        guard senderKey.isValidSignature(message.signature, for: signingData) else {
            throw ServiceMessageCryptoError.signatureVerificationFailed
        }

        // Reconstruct private key
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: recipientPrivateKey)

        // Reconstruct ephemeral public key
        let ephemeralPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.ephemeralPublicKey)

        // ECDH to get shared secret
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublic)

        // HKDF to derive decryption key
        let decryptionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: serviceMessageDomain.data(using: .utf8)!,
            sharedInfo: Data(),
            outputByteCount: 32
        )

        // XChaCha20-Poly1305 decrypt
        return try CryptoManager.decryptXChaCha20Poly1305(
            ciphertext: message.ciphertext,
            key: decryptionKey,
            nonce: message.nonce
        )
    }

    // MARK: - Contract Signing

    /// Create a contract sign request to send to the vault
    /// - Parameters:
    ///   - serviceId: Service GUID
    ///   - offeringId: Offering ID being subscribed to
    ///   - offeringSnapshot: Snapshot of the contract offering
    ///   - selectedFields: Fields the user agreed to share
    /// - Returns: Contract sign request with generated connection keypair
    static func createContractSignRequest(
        serviceId: String,
        offeringId: String,
        offeringSnapshot: ServiceDataContract,
        selectedFields: [SharedFieldMapping]
    ) throws -> (request: ContractSignRequest, connectionPrivateKey: Data) {
        // Generate X25519 keypair for this connection
        let (privateKey, publicKey) = try generateConnectionKeypair()

        let request = ContractSignRequest(
            eventId: UUID().uuidString,
            eventType: "service.contract.sign",
            contract: UnsignedServiceContract(
                serviceId: serviceId,
                offeringId: offeringId,
                offeringSnapshot: offeringSnapshot,
                userConnectionKey: publicKey.base64EncodedString(),
                selectedFields: selectedFields
            )
        )

        return (request, privateKey)
    }
}

// MARK: - Message Types

/// Encrypted message for service communication
struct ServiceEncryptedMessage: Codable {
    let eventId: String
    let ephemeralPublicKey: Data  // 32 bytes
    let nonce: Data               // 24 bytes (XChaCha20)
    let ciphertext: Data          // ciphertext + 16-byte tag
    let signature: Data           // Ed25519 signature

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case ephemeralPublicKey = "ephemeral_public_key"
        case nonce
        case ciphertext
        case signature
    }

    /// Combined representation for NATS transmission
    var combinedPayload: Data {
        ephemeralPublicKey + nonce + ciphertext
    }

    /// Create from combined payload
    init(eventId: String, ephemeralPublicKey: Data, nonce: Data, ciphertext: Data, signature: Data) {
        self.eventId = eventId
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.signature = signature
    }
}

// MARK: - Contract Signing Types

/// Request to sign a service contract via the vault
struct ContractSignRequest: Codable {
    let eventId: String
    let eventType: String
    let contract: UnsignedServiceContract

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case eventType = "event_type"
        case contract
    }
}

/// Unsigned contract to be signed by the vault
struct UnsignedServiceContract: Codable {
    let serviceId: String
    let offeringId: String
    let offeringSnapshot: ServiceDataContract
    let userConnectionKey: String  // Base64-encoded X25519 public key
    let selectedFields: [SharedFieldMapping]

    enum CodingKeys: String, CodingKey {
        case serviceId = "service_id"
        case offeringId = "offering_id"
        case offeringSnapshot = "offering_snapshot"
        case userConnectionKey = "user_connection_key"
        case selectedFields = "selected_fields"
    }
}

/// Response from vault after signing a contract
struct ContractSignResponse: Codable {
    let eventId: String
    let success: Bool
    let error: String?
    let result: SignedContractResult?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case success
        case error
        case result
    }
}

/// Result containing the signed contract
struct SignedContractResult: Codable {
    let contractId: String
    let signedContract: SignedServiceContract
    let natsCredentials: ServiceNATSCredentials
    let serviceConnectionKey: String  // Service's X25519 public key (base64)
    let serviceSigningKey: String     // Service's Ed25519 public key (base64)

    enum CodingKeys: String, CodingKey {
        case contractId = "contract_id"
        case signedContract = "signed_contract"
        case natsCredentials = "nats_credentials"
        case serviceConnectionKey = "service_connection_key"
        case serviceSigningKey = "service_signing_key"
    }
}

/// Signed service connection contract
struct SignedServiceContract: Codable {
    let contractId: String
    let serviceId: String
    let offeringId: String
    let version: Int
    let userSignature: String        // User's Ed25519 signature (base64)
    let serviceSignature: String?    // Service's Ed25519 signature (base64)
    let userConnectionKey: String    // User's X25519 public key (base64)
    let createdAt: Date
    let activatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case contractId = "contract_id"
        case serviceId = "service_id"
        case offeringId = "offering_id"
        case version
        case userSignature = "user_signature"
        case serviceSignature = "service_signature"
        case userConnectionKey = "user_connection_key"
        case createdAt = "created_at"
        case activatedAt = "activated_at"
    }
}

/// NATS credentials for connecting to a service's NATS cluster
struct ServiceNATSCredentials: Codable {
    let serviceId: String
    let endpoint: String
    let jwt: String
    let seed: String
    let expiresAt: Date?
    let subjects: ServiceNATSSubjects

    enum CodingKeys: String, CodingKey {
        case serviceId = "service_id"
        case endpoint
        case jwt
        case seed
        case expiresAt = "expires_at"
        case subjects
    }
}

/// NATS subjects for service communication
struct ServiceNATSSubjects: Codable {
    let publish: String      // Subject to publish messages to service
    let subscribe: String    // Subject to subscribe for messages from service

    enum CodingKeys: String, CodingKey {
        case publish
        case subscribe
    }
}

// MARK: - Auth/Authz Request Types

/// Authentication request from a service
struct ServiceAuthRequest: Codable, Identifiable {
    let id: String
    let serviceId: String
    let serviceName: String
    let serviceLogoUrl: String?
    let domainVerified: Bool
    let purpose: String
    let scopes: [String]
    let requestedAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "request_id"
        case serviceId = "service_id"
        case serviceName = "service_name"
        case serviceLogoUrl = "service_logo_url"
        case domainVerified = "domain_verified"
        case purpose
        case scopes
        case requestedAt = "requested_at"
        case expiresAt = "expires_at"
    }

    var timeRemaining: String {
        let remaining = expiresAt.timeIntervalSinceNow
        if remaining <= 0 { return "Expired" }
        let minutes = Int(remaining / 60)
        let seconds = Int(remaining.truncatingRemainder(dividingBy: 60))
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

/// Authorization request from a service (for specific actions)
struct ServiceAuthzRequest: Codable, Identifiable {
    let id: String
    let serviceId: String
    let serviceName: String
    let serviceLogoUrl: String?
    let domainVerified: Bool
    let action: String
    let resource: String?
    let context: [String: String]
    let purpose: String
    let requestedAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "request_id"
        case serviceId = "service_id"
        case serviceName = "service_name"
        case serviceLogoUrl = "service_logo_url"
        case domainVerified = "domain_verified"
        case action
        case resource
        case context
        case purpose
        case requestedAt = "requested_at"
        case expiresAt = "expires_at"
    }

    var timeRemaining: String {
        let remaining = expiresAt.timeIntervalSinceNow
        if remaining <= 0 { return "Expired" }
        let minutes = Int(remaining / 60)
        let seconds = Int(remaining.truncatingRemainder(dividingBy: 60))
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

/// Response to auth/authz request
struct ServiceAuthDecision: Codable {
    let requestId: String
    let approved: Bool
    let decidedAt: Date
    let signature: String?  // Signature over decision if approved

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case approved
        case decidedAt = "decided_at"
        case signature
    }
}

// MARK: - Errors

enum ServiceMessageCryptoError: Error, LocalizedError {
    case signatureVerificationFailed
    case invalidPublicKey
    case invalidPrivateKey
    case encryptionFailed
    case decryptionFailed
    case keypairGenerationFailed

    var errorDescription: String? {
        switch self {
        case .signatureVerificationFailed:
            return "Message signature verification failed"
        case .invalidPublicKey:
            return "Invalid public key format"
        case .invalidPrivateKey:
            return "Invalid private key format"
        case .encryptionFailed:
            return "Message encryption failed"
        case .decryptionFailed:
            return "Message decryption failed"
        case .keypairGenerationFailed:
            return "Failed to generate keypair"
        }
    }
}
