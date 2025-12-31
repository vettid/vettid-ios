import Foundation

// MARK: - Encrypted Message Envelope

/// Encrypted envelope for all app-vault NATS communication
/// Uses ChaCha20-Poly1305 with session keys derived from X25519 key exchange
struct EncryptedEnvelope: Codable {
    /// Protocol version for backwards compatibility
    let version: Int

    /// Session ID from bootstrap handshake
    let sessionId: String

    /// Base64-encoded ChaCha20-Poly1305 ciphertext
    let ciphertext: String

    /// Base64-encoded 12-byte nonce
    let nonce: String

    /// Optional ephemeral public key for key rotation (Base64)
    let ephemeralPublicKey: String?

    init(
        sessionId: String,
        ciphertext: String,
        nonce: String,
        ephemeralPublicKey: String? = nil,
        version: Int = 1
    ) {
        self.version = version
        self.sessionId = sessionId
        self.ciphertext = ciphertext
        self.nonce = nonce
        self.ephemeralPublicKey = ephemeralPublicKey
    }

    enum CodingKeys: String, CodingKey {
        case version
        case sessionId = "session_id"
        case ciphertext
        case nonce
        case ephemeralPublicKey = "ephemeral_public_key"
    }
}

// MARK: - Bootstrap Types

/// Request to initiate E2E session with vault
struct BootstrapRequest: Codable {
    /// Unique request identifier for correlation
    let requestId: String

    /// App's ephemeral X25519 public key (Base64)
    let appPublicKey: String

    /// Device identifier for logging/audit
    let deviceId: String

    /// ISO8601 timestamp
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case appPublicKey = "app_public_key"
        case deviceId = "device_id"
        case timestamp
    }
}

/// Response from vault with session establishment data
struct BootstrapResponse: Codable {
    /// Matching request ID for correlation
    let requestId: String

    /// Vault's ephemeral X25519 public key (Base64)
    let vaultPublicKey: String

    /// Assigned session ID for this E2E channel
    let sessionId: String

    /// Updated NATS credentials (.creds file content)
    let credentials: String?

    /// Credential TTL in seconds
    let credentialsTtl: Int?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case vaultPublicKey = "vault_public_key"
        case sessionId = "session_id"
        case credentials
        case credentialsTtl = "credentials_ttl"
    }
}

// MARK: - Key Rotation Types

/// Request to rotate session keys
struct KeyRotationRequest: Codable {
    /// Current session ID
    let sessionId: String

    /// New ephemeral public key (Base64)
    let newPublicKey: String

    /// ISO8601 timestamp
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case newPublicKey = "new_public_key"
        case timestamp
    }
}

/// Acknowledgment of key rotation
struct KeyRotationAck: Codable {
    /// Session ID (same as request)
    let sessionId: String

    /// Vault's new ephemeral public key if vault-initiated rotation (Base64)
    let vaultPublicKey: String?

    /// Whether rotation was successful
    let success: Bool

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case vaultPublicKey = "vault_public_key"
        case success
    }
}

// MARK: - Session State

/// Persisted session state for recovery after app restart
struct SessionState: Codable {
    /// Session identifier
    let sessionId: String

    /// When session was established
    let establishedAt: Date

    /// Number of messages encrypted with current key
    let messageCount: Int

    /// Session key (stored separately in Keychain)
    /// This struct only holds metadata, not the actual key

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case establishedAt = "established_at"
        case messageCount = "message_count"
    }
}

// MARK: - Decrypted Message Wrapper

/// Wrapper for decrypted NATS messages with metadata
struct DecryptedMessage<T: Decodable> {
    /// Session this message was received on
    let sessionId: String

    /// Original encrypted envelope
    let envelope: EncryptedEnvelope

    /// Decrypted and decoded payload
    let payload: T

    /// When the message was decrypted
    let decryptedAt: Date
}
