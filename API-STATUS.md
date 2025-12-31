# VettID iOS API Status

**Last Updated:** 2025-12-31

This file tracks API implementation status for VettID iOS, aligned with the backend API-STATUS.md and Android implementation.

---

## Endpoint Status

| Endpoint | Status | iOS Implementation |
|----------|--------|-------------------|
| POST /api/v1/enroll/start | **Implemented** | `EnrollmentService.startEnrollment()` |
| POST /api/v1/enroll/set-password | **Implemented** | `EnrollmentService.setPassword()` |
| POST /api/v1/enroll/finalize | **Implemented** | `EnrollmentService.finalize()` |
| POST /api/v1/action/request | **Implemented** | `AuthenticationService.requestAction()` |
| POST /api/v1/auth/execute | **Implemented** | `AuthenticationService.authenticate()` |
| GET /vault/health | **Implemented** | `APIClient.getVaultHealth()` |
| GET /vault/status | **Implemented** | `APIClient.getVaultStatus()` |
| POST /vault/start | **Implemented** | `APIClient.startVaultInstance()` |
| POST /vault/stop | **Implemented** | `APIClient.stopVaultInstance()` |
| POST /vault/terminate | **Implemented** | `APIClient.terminateVault()` |

---

## NATS Handler Status

| Handler | Status | iOS Implementation |
|---------|--------|-------------------|
| `app.bootstrap` | **Implemented** | `SessionKeyManager` + `NatsConnectionManager.performBootstrap()` |
| `secrets.datastore.*` | **Implemented** | `SecretsHandler` actor |
| `profile.*` | **Implemented** | `ProfileHandler` actor |
| `credentials.*` | **Implemented** | `CredentialsHandler` actor |
| `connection.*` | **Implemented** | `ConnectionHandler` actor |
| `message.send` | **Implemented** | `MessageHandler` actor |
| `message.read-receipt` | **Implemented** | `MessageHandler` actor |
| `profile.broadcast` | **Implemented** | `MessageHandler` actor |
| `connection.notify-revoke` | **Implemented** | `MessageHandler` actor |

---

## Recent Changes

### 2025-12-31 - Phase 4: MessageHandler Implemented

- **Files:** `VettID/Core/NATS/Handlers/MessageHandler.swift`, `VettID/Features/Messaging/ConversationViewModel.swift`

- **Features:**
  - `message.send` - Send encrypted messages to peer vaults
  - `message.read-receipt` - Send read receipts to sender vault
  - `profile.broadcast` - Broadcast profile updates to all connections
  - `connection.notify-revoke` - Notify peer of connection revocation

- **Architecture:** Messages flow vault-to-vault via NATS MessageSpace
  - App → Vault (OwnerSpace.forVault) → Peer Vault (MessageSpace.forOwner) → Peer App

- **ConversationViewModel Updates:**
  - `configureMessageHandler()` for NATS integration
  - Uses MessageHandler when available, falls back to API
  - `handleIncomingMessage()` for real-time message processing
  - `handleReadReceipt()` for receipt handling

- **Mobile Action Required:**
  - [x] iOS: Implement `message.send` for sending messages - `MessageHandler.sendMessage()`
  - [x] iOS: Implement `message.read-receipt` - `MessageHandler.sendReadReceipt()`
  - [x] iOS: Implement `profile.broadcast` - `MessageHandler.broadcastProfileUpdate()`
  - [x] iOS: Update ConversationViewModel to use MessageHandler

### 2025-12-31 - Phase 3: NATS Vault Handlers Implemented

- **Files:** `VettID/Core/NATS/Handlers/*.swift`

- **Handlers Implemented:**
  - `SecretsHandler` - CRUD for encrypted secrets (`secrets.datastore.*`)
  - `ProfileHandler` - Profile field management (`profile.*`)
  - `CredentialsHandler` - Credential lifecycle (`credentials.*`, `credential.*`)
  - `ConnectionHandler` - Peer connections (`connection.*`)

- **All handlers use:**
  - Actor isolation for concurrency safety
  - `VaultResponseHandler` for request/response correlation
  - `AnyCodableValue` for flexible JSON payloads

- **Mobile Action Required:**
  - [x] iOS: Implement SecretsHandler
  - [x] iOS: Implement ProfileHandler
  - [x] iOS: Implement CredentialsHandler
  - [x] iOS: Implement ConnectionHandler

### 2025-12-31 - Phase 1-2: E2E Bootstrap & Vault Lifecycle

- **Files:**
  - `VettID/Core/NATS/SessionKeyManager.swift` - E2E session management
  - `VettID/Core/NATS/EncryptedEnvelope.swift` - Encrypted message types
  - `VettID/Features/Vault/VaultHealthViewModel.swift` - Lifecycle management

- **E2E Session Encryption:**
  - X25519 ECDH key exchange during `app.bootstrap`
  - HKDF-SHA256 session key derivation ("app-vault-session-v1")
  - ChaCha20-Poly1305 message encryption
  - Session persistence in Keychain
  - Key rotation triggers (1000 messages or 24 hours)

- **Vault Lifecycle:**
  - `startVault()` - Start stopped vault instance
  - `pollForStartup()` - Monitor provisioning progress
  - `needsAttention` - Health status indicator

- **Mobile Action Required:**
  - [x] iOS: Implement SessionKeyManager for E2E encryption
  - [x] iOS: Add `performBootstrap()` to NatsConnectionManager
  - [x] iOS: Update VaultEventClient to encrypt messages
  - [x] iOS: Add vault start/stop controls

### 2025-11-27 - Initial API Deployment

- **Endpoints:** All enrollment and authentication endpoints deployed
- **Mobile Action Required:**
  - [x] iOS: Implement multi-step enrollment flow
  - [x] iOS: Implement action-specific authentication flow
  - [x] iOS: Update crypto to handle UTK encryption

---

## iOS Implementation Details

### Key Files

| Component | File | Description |
|-----------|------|-------------|
| **Enrollment** | `EnrollmentService.swift` | Multi-step enrollment flow |
| **Authentication** | `AuthenticationService.swift` | Action-token auth flow |
| **API Client** | `APIClient.swift` | HTTP client for Ledger Service |
| **NATS Connection** | `NatsConnectionManager.swift` | NATS lifecycle + bootstrap |
| **Session Crypto** | `SessionKeyManager.swift` | E2E encryption for app-vault |
| **Vault Events** | `VaultEventClient.swift` | Event submission with encryption |
| **Response Handler** | `VaultResponseHandler.swift` | Request/response correlation |
| **Secrets** | `SecretsHandler.swift` | Encrypted secrets CRUD |
| **Profile** | `ProfileHandler.swift` | Profile field management |
| **Credentials** | `CredentialsHandler.swift` | Credential lifecycle |
| **Connections** | `ConnectionHandler.swift` | Peer connection management |
| **Messaging** | `MessageHandler.swift` | Vault-to-vault messaging |

### Cryptographic Implementation

| Operation | iOS Implementation |
|-----------|-------------------|
| X25519 ECDH | `CryptoKit.Curve25519.KeyAgreement` |
| ChaCha20-Poly1305 | `CryptoKit.ChaChaPoly` |
| HKDF-SHA256 | `CryptoKit.HKDF` (via SharedSecret) |
| Argon2id | `PasswordHasher` (PBKDF2 fallback until swift-sodium added) |
| Ed25519 Signing | `CryptoKit.Curve25519.Signing` |

### Storage

| Data | Storage Location |
|------|------------------|
| Credentials (blob, LAT, UTKs) | Keychain (`.afterFirstUnlockThisDeviceOnly`) |
| Session keys | Keychain |
| NATS credentials | `NatsCredentialStore` (Keychain) |
| Profile data | `ProfileStore` (Keychain) |
| Secrets | `SecretsStore` (Keychain + ChaCha20 encryption) |

### NATS Message Format

iOS sends messages matching vault-manager expectations:

```swift
struct VaultEventMessage: Encodable {
    let id: String           // UUID for correlation
    let type: String         // Handler type (e.g., "profile.get")
    let payload: [String: AnyCodableValue]
    let timestamp: String    // ISO 8601
}
```

Response parsing handles both field names:
```swift
struct VaultEventResponse: Decodable {
    let eventId: String?     // Primary field from vault
    let id: String?          // Fallback field
    let success: Bool
    // ...

    var responseId: String {
        eventId ?? id ?? ""
    }
}
```

---

## Incoming Notifications (Vault → App)

Subscribe to `forApp.*` topics for real-time notifications:

| Topic | iOS Type | Description |
|-------|----------|-------------|
| `forApp.new-message` | `IncomingMessage` | New message from peer |
| `forApp.read-receipt` | `IncomingReadReceipt` | Peer read your message |
| `forApp.profile-update` | `IncomingProfileUpdate` | Profile update from peer |
| `forApp.connection-revoked` | `IncomingConnectionRevoked` | Peer revoked connection |
| `forApp.credentials.rotate` | *Pending* | Vault-initiated credential rotation |

---

## Implementation Checklist

### Enrollment & Auth
- [x] Multi-step enrollment (start → set-password → finalize)
- [x] Action-token authentication flow
- [x] LAT verification (anti-phishing)
- [x] UTK pool management
- [x] Credential rotation on auth

### NATS Communication
- [x] NATS connection with JWT/seed auth
- [x] E2E bootstrap key exchange
- [x] Session key derivation (HKDF)
- [x] Message encryption (ChaCha20-Poly1305)
- [x] Session persistence in Keychain
- [x] Request/response correlation

### Vault Handlers
- [x] `secrets.datastore.*` - Secrets CRUD
- [x] `profile.*` - Profile management
- [x] `credentials.*` - Credential lifecycle
- [x] `connection.*` - Connection management
- [x] `message.*` - Vault-to-vault messaging

### Vault Lifecycle
- [x] Health status monitoring
- [x] Start/stop vault instance
- [x] Provisioning polling
- [ ] Background sync (BGAppRefreshTask)

### Pending
- [ ] Subscribe to `forApp.credentials.rotate` for proactive rotation
- [ ] Implement credential rotation handler
- [ ] Background sync worker (like Android WorkManager)
- [ ] Add swift-sodium for native Argon2id
- [ ] Add nats.swift for production NATS connectivity

---

## Known Differences from Android

| Feature | Android | iOS |
|---------|---------|-----|
| NATS Library | `nats.java` | Stub wrapper (pending `nats.swift`) |
| Argon2id | `argon2-jvm` | PBKDF2 fallback (pending `swift-sodium`) |
| Background Sync | WorkManager | BGAppRefreshTask (pending) |
| Keystore | Android Keystore | iOS Keychain |
| Attestation | SafetyNet/Play Integrity | App Attest |

---

## API Specifications

### Key Ownership Model

**Ledger (Backend) Owns:**
- CEK (Credential Encryption Key) - X25519 private key for encrypting credential blob
- LTK (Ledger Transaction Key) - X25519 private key for decrypting password hashes

**Mobile Stores:**
- Encrypted credential blob (cannot decrypt without CEK)
- UTK pool (User Transaction Keys) - X25519 **public** keys for encrypting password
- LAT (Ledger Auth Token) - 256-bit token for verifying server authenticity

### Password Encryption Flow

1. User enters password
2. Hash with Argon2id: `password_hash = Argon2id(password, salt)`
3. Generate ephemeral X25519 keypair
4. Compute shared secret: `shared = X25519(ephemeral_private, UTK_public)`
5. Derive encryption key: `key = HKDF-SHA256(shared, "password-encryption")`
6. Encrypt: `encrypted = ChaCha20-Poly1305(password_hash, key, nonce)`
7. Send: `encrypted_password_hash`, `ephemeral_public_key`, `nonce`, `key_id`

### NATS Topics

| Topic | Direction | Purpose |
|-------|-----------|---------|
| `OwnerSpace.{user_guid}.forVault.>` | App → Vault | Send commands to vault |
| `OwnerSpace.{user_guid}.forApp.>` | Vault → App | Receive responses from vault |
| `MessageSpace.{user_guid}.forOwner.>` | Peer Vault → Your Vault | Incoming peer messages |

---

## Testing

### Build Command
```bash
xcodebuild -scheme VettID -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

### Simulator Testing
```bash
# Boot simulator
xcrun simctl boot "iPhone 17"
open -a Simulator

# Install app
xcrun simctl install booted build/Debug-iphonesimulator/VettID.app
```

### Device Logs
```bash
# Stream device logs (requires libimobiledevice)
idevicesyslog | grep VettID
```

---

## Issues

### Open

*No open issues*

### Resolved

#### NATS Message Format Alignment
**Status:** ✅ Fixed (2025-12-30)
**Affected:** `VaultEventMessage`, `VaultEventResponse`

iOS was sending messages with field names that didn't match vault-manager. Fixed:
- ✅ Changed `request_id` to `id` in VaultEventMessage
- ✅ Response parsing uses `event_id` with fallback to `id`
- ✅ Timestamps use ISO 8601 string format

#### App-Vault E2E Encryption Implemented
**Status:** ✅ Completed (2025-12-31)
**Affected:** `SessionKeyManager.swift`, `NatsConnectionManager.swift`, `VaultEventClient.swift`

Implemented end-to-end encryption for app-vault NATS communication:
- ✅ X25519 ECDH key exchange during `app.bootstrap`
- ✅ HKDF-SHA256 session key derivation ("app-vault-session-v1")
- ✅ ChaCha20-Poly1305 message encryption
- ✅ Encrypted payload in sendToVault (bootstrap messages excluded)
- ✅ Session persistence in Keychain
- ✅ Session restoration on app restart
