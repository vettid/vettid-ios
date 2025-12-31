import Foundation
import CryptoKit

/// Manages E2E encryption session with the vault
///
/// Handles:
/// - Bootstrap key exchange (X25519)
/// - Session key derivation (HKDF)
/// - Message encryption/decryption (ChaCha20-Poly1305)
/// - Key rotation triggers
actor SessionKeyManager {

    // MARK: - Types

    enum SessionError: LocalizedError {
        case noActiveSession
        case bootstrapInProgress
        case bootstrapFailed(String)
        case encryptionFailed(String)
        case decryptionFailed(String)
        case invalidPublicKey
        case keyRotationRequired
        case sessionExpired

        var errorDescription: String? {
            switch self {
            case .noActiveSession:
                return "No active E2E session with vault"
            case .bootstrapInProgress:
                return "Bootstrap already in progress"
            case .bootstrapFailed(let reason):
                return "Bootstrap failed: \(reason)"
            case .encryptionFailed(let reason):
                return "Encryption failed: \(reason)"
            case .decryptionFailed(let reason):
                return "Decryption failed: \(reason)"
            case .invalidPublicKey:
                return "Invalid public key format"
            case .keyRotationRequired:
                return "Session key rotation required"
            case .sessionExpired:
                return "Session has expired"
            }
        }
    }

    // MARK: - Session State

    private var sessionId: String?
    private var sessionKey: SymmetricKey?
    private var messageCount: Int = 0
    private var sessionStartTime: Date?

    // MARK: - Bootstrap State

    private var pendingBootstrap: (
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        requestId: String
    )?

    // MARK: - Configuration

    /// Maximum messages before requiring key rotation
    private let maxMessages = 1000

    /// Maximum session age before requiring rotation (24 hours)
    private let maxSessionAge: TimeInterval = 86400

    /// HKDF info string for session key derivation
    private let sessionKeyInfo = "app-vault-session-v1"

    /// HKDF salt (must match across platforms)
    private let hkdfSalt = "VettID-HKDF-Salt-v1"

    // MARK: - Keychain Keys

    private let keychainSessionIdKey = "com.vettid.session.id"
    private let keychainSessionKeyKey = "com.vettid.session.key"
    private let keychainSessionStartKey = "com.vettid.session.start"
    private let keychainMessageCountKey = "com.vettid.session.messageCount"

    // MARK: - Initialization

    init() {
        // Try to restore session from Keychain on init
        Task {
            await restoreSession()
        }
    }

    // MARK: - Bootstrap Flow

    /// Initiate bootstrap key exchange with vault
    /// - Returns: BootstrapRequest to send via NATS
    func initiateBootstrap() throws -> BootstrapRequest {
        guard pendingBootstrap == nil else {
            throw SessionError.bootstrapInProgress
        }

        // Generate ephemeral X25519 keypair
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey

        let requestId = UUID().uuidString

        // Store pending bootstrap state
        pendingBootstrap = (privateKey: privateKey, requestId: requestId)

        return BootstrapRequest(
            requestId: requestId,
            appPublicKey: publicKey.rawRepresentation.base64EncodedString(),
            deviceId: getDeviceId(),
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// Complete bootstrap with vault's response
    /// - Parameter response: BootstrapResponse from vault
    func completeBootstrap(response: BootstrapResponse) throws {
        guard let pending = pendingBootstrap else {
            throw SessionError.bootstrapFailed("No pending bootstrap request")
        }

        guard pending.requestId == response.requestId else {
            throw SessionError.bootstrapFailed("Request ID mismatch")
        }

        // Decode vault's public key
        guard let vaultPublicKeyData = Data(base64Encoded: response.vaultPublicKey) else {
            throw SessionError.invalidPublicKey
        }

        let vaultPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            vaultPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: vaultPublicKeyData
            )
        } catch {
            throw SessionError.invalidPublicKey
        }

        // Derive shared secret via X25519
        let sharedSecret = try pending.privateKey.sharedSecretFromKeyAgreement(
            with: vaultPublicKey
        )

        // Derive session key using HKDF
        let salt = hkdfSalt.data(using: .utf8)!
        let info = sessionKeyInfo.data(using: .utf8)!

        let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )

        // Establish session
        sessionId = response.sessionId
        sessionKey = derivedKey
        sessionStartTime = Date()
        messageCount = 0

        // Clear pending bootstrap
        pendingBootstrap = nil

        // Persist session to Keychain
        try persistSession()

        #if DEBUG
        print("[SessionKeyManager] Bootstrap complete, sessionId: \(response.sessionId)")
        #endif
    }

    /// Cancel pending bootstrap
    func cancelBootstrap() {
        pendingBootstrap = nil
    }

    // MARK: - Encryption/Decryption

    /// Encrypt a message for transmission to vault
    /// - Parameter message: Plaintext data to encrypt
    /// - Returns: EncryptedEnvelope ready for NATS transmission
    func encrypt(message: Data) throws -> EncryptedEnvelope {
        guard let sessionId = sessionId, let key = sessionKey else {
            throw SessionError.noActiveSession
        }

        // Check if rotation is needed
        if shouldRotateKey() {
            throw SessionError.keyRotationRequired
        }

        // Generate random nonce
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, 12, &nonceBytes)
        let nonceData = Data(nonceBytes)
        let nonce = try ChaChaPoly.Nonce(data: nonceData)

        // Encrypt with ChaCha20-Poly1305
        let sealedBox = try ChaChaPoly.seal(message, using: key, nonce: nonce)

        // Combine ciphertext and tag
        let ciphertext = sealedBox.ciphertext + sealedBox.tag

        // Increment message counter
        messageCount += 1
        try? updateMessageCount()

        return EncryptedEnvelope(
            sessionId: sessionId,
            ciphertext: ciphertext.base64EncodedString(),
            nonce: nonceData.base64EncodedString()
        )
    }

    /// Decrypt a message received from vault
    /// - Parameter envelope: EncryptedEnvelope from NATS
    /// - Returns: Decrypted plaintext data
    func decrypt(envelope: EncryptedEnvelope) throws -> Data {
        guard let currentSessionId = sessionId, let key = sessionKey else {
            throw SessionError.noActiveSession
        }

        // Verify session ID matches
        guard envelope.sessionId == currentSessionId else {
            throw SessionError.decryptionFailed("Session ID mismatch")
        }

        // Decode ciphertext and nonce
        guard let ciphertextWithTag = Data(base64Encoded: envelope.ciphertext),
              let nonceData = Data(base64Encoded: envelope.nonce) else {
            throw SessionError.decryptionFailed("Invalid base64 encoding")
        }

        // Split ciphertext and tag (tag is last 16 bytes)
        guard ciphertextWithTag.count >= 16 else {
            throw SessionError.decryptionFailed("Ciphertext too short")
        }

        let tagIndex = ciphertextWithTag.count - 16
        let ciphertext = ciphertextWithTag.prefix(tagIndex)
        let tag = ciphertextWithTag.suffix(16)

        // Reconstruct sealed box
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )

        // Decrypt
        return try ChaChaPoly.open(sealedBox, using: key)
    }

    // MARK: - Key Rotation

    /// Check if session key should be rotated
    func shouldRotateKey() -> Bool {
        // No session = no rotation needed
        guard sessionStartTime != nil else {
            return false
        }

        // Check message count
        if messageCount >= maxMessages {
            return true
        }

        // Check session age
        if let startTime = sessionStartTime,
           Date().timeIntervalSince(startTime) >= maxSessionAge {
            return true
        }

        return false
    }

    /// Initiate key rotation
    /// - Returns: KeyRotationRequest to send via NATS
    func initiateKeyRotation() throws -> (KeyRotationRequest, Curve25519.KeyAgreement.PrivateKey) {
        guard let currentSessionId = sessionId else {
            throw SessionError.noActiveSession
        }

        // Generate new ephemeral keypair
        let newPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let newPublicKey = newPrivateKey.publicKey

        let request = KeyRotationRequest(
            sessionId: currentSessionId,
            newPublicKey: newPublicKey.rawRepresentation.base64EncodedString(),
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        return (request, newPrivateKey)
    }

    /// Complete key rotation with vault's acknowledgment
    func completeKeyRotation(
        ack: KeyRotationAck,
        ourPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws {
        guard ack.success else {
            throw SessionError.bootstrapFailed("Key rotation rejected by vault")
        }

        guard let vaultPublicKeyBase64 = ack.vaultPublicKey,
              let vaultPublicKeyData = Data(base64Encoded: vaultPublicKeyBase64) else {
            throw SessionError.invalidPublicKey
        }

        let vaultPublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: vaultPublicKeyData
        )

        // Derive new shared secret
        let sharedSecret = try ourPrivateKey.sharedSecretFromKeyAgreement(
            with: vaultPublicKey
        )

        // Derive new session key
        let salt = hkdfSalt.data(using: .utf8)!
        let info = sessionKeyInfo.data(using: .utf8)!

        let newKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )

        // Update session with new key
        sessionKey = newKey
        sessionStartTime = Date()
        messageCount = 0

        try persistSession()

        #if DEBUG
        print("[SessionKeyManager] Key rotation complete")
        #endif
    }

    // MARK: - Session Management

    /// Check if an active session exists
    var hasActiveSession: Bool {
        sessionId != nil && sessionKey != nil
    }

    /// Get current session ID
    var currentSessionId: String? {
        sessionId
    }

    /// Clear the current session
    func clearSession() {
        sessionId = nil
        sessionKey = nil
        sessionStartTime = nil
        messageCount = 0
        pendingBootstrap = nil

        // Clear from Keychain
        clearKeychainSession()
    }

    // MARK: - Persistence

    private func persistSession() throws {
        guard let sessionId = sessionId,
              let sessionKey = sessionKey,
              let sessionStartTime = sessionStartTime else {
            return
        }

        // Store session ID
        let sessionIdData = sessionId.data(using: .utf8)!
        try storeInKeychain(data: sessionIdData, key: keychainSessionIdKey)

        // Store session key
        let keyData = sessionKey.withUnsafeBytes { Data($0) }
        try storeInKeychain(data: keyData, key: keychainSessionKeyKey)

        // Store session start time
        let startTimeData = String(sessionStartTime.timeIntervalSince1970).data(using: .utf8)!
        try storeInKeychain(data: startTimeData, key: keychainSessionStartKey)

        // Store message count
        let countData = String(messageCount).data(using: .utf8)!
        try storeInKeychain(data: countData, key: keychainMessageCountKey)
    }

    private func restoreSession() {
        guard let sessionIdData = loadFromKeychain(key: keychainSessionIdKey),
              let sessionId = String(data: sessionIdData, encoding: .utf8),
              let keyData = loadFromKeychain(key: keychainSessionKeyKey),
              keyData.count == 32 else {
            return
        }

        self.sessionId = sessionId
        self.sessionKey = SymmetricKey(data: keyData)

        // Restore start time
        if let startData = loadFromKeychain(key: keychainSessionStartKey),
           let startString = String(data: startData, encoding: .utf8),
           let startInterval = Double(startString) {
            self.sessionStartTime = Date(timeIntervalSince1970: startInterval)
        }

        // Restore message count
        if let countData = loadFromKeychain(key: keychainMessageCountKey),
           let countString = String(data: countData, encoding: .utf8),
           let count = Int(countString) {
            self.messageCount = count
        }

        #if DEBUG
        print("[SessionKeyManager] Restored session: \(sessionId)")
        #endif
    }

    private func updateMessageCount() throws {
        let countData = String(messageCount).data(using: .utf8)!
        try storeInKeychain(data: countData, key: keychainMessageCountKey)
    }

    private func clearKeychainSession() {
        deleteFromKeychain(key: keychainSessionIdKey)
        deleteFromKeychain(key: keychainSessionKeyKey)
        deleteFromKeychain(key: keychainSessionStartKey)
        deleteFromKeychain(key: keychainMessageCountKey)
    }

    // MARK: - Keychain Helpers

    private func storeInKeychain(data: Data, key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SessionError.encryptionFailed("Failed to store in Keychain: \(status)")
        }
    }

    private func loadFromKeychain(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            return nil
        }

        return result as? Data
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Helpers

    private nonisolated func getDeviceId() -> String {
        let key = "com.vettid.device_id"
        if let deviceId = UserDefaults.standard.string(forKey: key) {
            return deviceId
        }
        // Generate a stable device ID using UUID (avoids MainActor requirement)
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}
