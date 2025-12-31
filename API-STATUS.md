# VettID iOS API Status

**Last Updated:** 2025-12-31 (Backend fixes for issues #1, #2, #3)

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
| GET /vault/health | **Implemented** | `APIClient.getVaultHealth()` (Cognito auth) |
| GET /vault/status | **Implemented** | `APIClient.getVaultStatus()` (Cognito auth) |
| POST /vault/start | **Implemented** | `APIClient.startVaultInstance()` (Cognito auth) |
| POST /vault/stop | **Implemented** | `APIClient.stopVaultInstance()` (Cognito auth) |
| POST /vault/terminate | **Implemented** | `APIClient.terminateVault()` (Cognito auth) |
| POST /api/v1/vault/start | **Implemented** | `APIClient.startVaultAction()` |
| POST /api/v1/vault/stop | **Implemented** | `APIClient.stopVaultAction()` |
| GET /api/v1/vault/status | **Implemented** | `APIClient.getVaultStatusAction()` |

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

## Backend Status Updates (2025-12-31)

### ✅ Issue #2 FIXED: Action Token 404 Error

The `/api/v1/action/request` endpoint was only available at `/vault/action/request` (with Cognito auth).
Mobile apps couldn't get action tokens because they don't have Cognito JWT.

**Fix:** Added public route `/api/v1/action/request` (no Cognito auth). User validation via DynamoDB credential lookup.

### ✅ Issue #3 FIXED: Test Vault Provisioning

The `/test/create-invitation` endpoint now accepts optional `user_guid` parameter to reuse existing vaults.

**Usage:**
```json
POST /test/create-invitation
{
  "test_user_id": "my_test",
  "user_guid": "user-D84E1A00643A4C679FAEF6D6FA81B103"
}
```

### ⚠️ Issue #1 PARTIAL: Bootstrap Topic Fix

The vault-manager bootstrap response topic fix is deployed, but **only on one vault**:

| user_guid | Has Bootstrap Fix | Use For Testing |
|-----------|-------------------|-----------------|
| `user-D84E1A00643A4C679FAEF6D6FA81B103` | ✅ Yes | ✅ Use this one |

All other test vaults have been terminated. Only the one with the fix remains.

**For full bootstrap flow testing, use `user-D84E1A00643A4C679FAEF6D6FA81B103`**

### ✅ NEW FIX: HTTP 500 from /api/v1/action/request

**Problem:** The `/api/v1/action/request` endpoint was returning HTTP 500 with DynamoDB error.

**Root Cause:** Lambda handler had incorrect DynamoDB queries that didn't match actual table schemas:
1. **Credentials table** - Used `GetItem` with just `user_guid`, but table has composite key
2. **LedgerAuthTokens table** - Queried by `user_guid`, but no GSI existed
3. **TransactionKeys table** - Queried using wrong GSI name

**Fix Applied:**
1. Changed Credentials query from `GetItem` to `Query`
2. Added `user-index` GSI to LedgerAuthTokens table
3. Fixed TransactionKeys to use correct GSI

**Status:** Deployed and active. The endpoint should now work correctly.

### ✅ NEW FIX: user_guid Vault Reuse

**Problem:** Passing `user_guid` to `/test/create-invitation` to reuse an existing vault didn't work. The enrollment created NEW NATS credentials that the vault didn't recognize.

**Root Cause:** `enrollFinalize.ts` generated new credentials before checking if the account existed.

**Fix Applied:** Now checks for existing NATS accounts FIRST:
1. If account exists: use existing `account_seed` for bootstrap credentials
2. If new user: create account and provision vault as before

**New Response:** `vault_status: "EXISTING"` means re-enrollment with existing vault:
```json
{
  "vault_status": "EXISTING",
  "vault_bootstrap": {
    "credentials": "...",  // Valid for existing vault
    "estimated_ready_at": "..."  // Immediate
  }
}
```

---

## Recent Changes

### 2025-12-31 - Action-Token Vault Lifecycle Endpoints Deployed

- **Endpoints:** New mobile-friendly vault lifecycle endpoints (no Cognito required)
  - `POST /api/v1/vault/start` - Start vault EC2 instance
  - `POST /api/v1/vault/stop` - Stop vault EC2 instance
  - `GET /api/v1/vault/status` - Get enrollment and instance status

- **Breaking:** No - New functionality only

- **Authentication:** Uses action tokens instead of Cognito JWT
  - Request action token via `/api/v1/action/request` with `action_type`: `vault_start`, `vault_stop`, or `vault_status`
  - Execute action with action token in Bearer header (single-use, 5-minute expiry)

- **New Action Types:**
  - `vault_start` → `/api/v1/vault/start`
  - `vault_stop` → `/api/v1/vault/stop`
  - `vault_status` → `/api/v1/vault/status`

- **Response Format:**
  ```json
  // POST /api/v1/vault/start
  {
    "status": "starting",
    "instance_id": "i-xxx",
    "message": "Vault is starting. Please wait for initialization to complete."
  }

  // GET /api/v1/vault/status
  {
    "enrollment_status": "active",
    "user_guid": "user_xxx",
    "transaction_keys_remaining": 15,
    "instance_status": "running",
    "instance_id": "i-xxx",
    "instance_ip": "x.x.x.x",
    "nats_endpoint": "tls://nats.vettid.dev:4222"
  }
  ```

- **Mobile Action Required:**
  - [x] iOS: Implement action-token vault lifecycle in APIClient
  - [x] iOS: Add vault start/stop to ManageVaultView
  - [x] iOS: Auto-start vault when NATS connection fails

### 2025-12-30 - Security Module Added

- **Files:** `VettID/Core/Security/ApiSecurity.swift`, `VettID/Info.plist`

- **Features:**
  - Request signing with HMAC-SHA256
  - Nonce-based replay protection
  - Request timestamp validation
  - Certificate pinning configuration (ready for custom domain)
  - URLRequest extension for security headers

- **Platform Parity with Android:**
  - Matches `ApiSecurity.kt` functionality
  - Matches `network_security_config.xml` pinning setup
  - Both platforms ready for `api.vettid.dev` custom domain

- **Mobile Action Required:**
  - [x] iOS: Implement request signing
  - [x] iOS: Implement replay protection
  - [x] iOS: Add certificate pinning config
  - [ ] Backend: Deploy custom domain for cert pinning

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

### 2025-12-31 - Background Sync Implemented

- **Files:** `VettID/Features/Vault/VaultBackgroundRefresh.swift`, `VettID/App/VettIDApp.swift`

- **Features:**
  - Vault sync task (15-minute interval) - checks transaction key pool, credential rotation
  - NATS credential refresh task (6-hour interval) - refreshes credentials before expiry
  - Smart scheduling based on credential expiration time
  - Notifications for low keys, rotation needed, refresh needed

- **Architecture:**
  - Uses iOS BGAppRefreshTask (equivalent to Android WorkManager)
  - Tasks registered via AppDelegate at app launch
  - Scheduled when app enters background (if enrolled)
  - Cancelled on logout/sign-out

- **Task Identifiers (in Info.plist):**
  - `dev.vettid.vault-refresh` - Vault sync
  - `dev.vettid.nats-token-refresh` - NATS credential refresh
  - `dev.vettid.backup` - Reserved for backup tasks

- **Parity with Android:**
  - `VaultSyncWorker` → `VaultBackgroundRefresh.performVaultSync()`
  - `NatsTokenRefreshWorker` → `VaultBackgroundRefresh.performNatsCredentialRefresh()`
  - Same thresholds: 5 UTKs, 2-hour refresh buffer

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
| **API Security** | `ApiSecurity.swift` | Request signing, replay protection, cert pinning docs |

### Cryptographic Implementation

| Operation | iOS Implementation |
|-----------|-------------------|
| X25519 ECDH | `CryptoKit.Curve25519.KeyAgreement` |
| ChaCha20-Poly1305 | `CryptoKit.ChaChaPoly` |
| HKDF-SHA256 | `CryptoKit.HKDF` (via SharedSecret) |
| Argon2id | `PasswordHasher` (PBKDF2 fallback until swift-sodium added) |
| Ed25519 Signing | `CryptoKit.Curve25519.Signing` |
| HMAC-SHA256 | `CryptoKit.HMAC<SHA256>` |

### Security

| Feature | Status | Implementation |
|---------|--------|----------------|
| HTTPS Only | ✅ Enabled | ATS (App Transport Security) in `Info.plist` |
| TLS 1.2+ | ✅ Enforced | ATS default requirement |
| Perfect Forward Secrecy | ✅ Required | ATS default requirement |
| Certificate Pinning | ⏸️ Ready | `Info.plist` NSPinnedDomains (disabled until custom domain) |
| Request Signing | ✅ Implemented | `ApiSecurity.signRequest()` HMAC-SHA256 |
| Replay Protection | ✅ Implemented | `ApiSecurity` nonce + timestamp validation |
| Request IDs | ✅ Implemented | `ApiSecurity.generateRequestId()` UUID |

#### Certificate Pinning Status

Certificate pinning is **prepared but disabled** because AWS API Gateway uses rotating certificates.

**When to enable:**
1. Backend deploys custom domain `api.vettid.dev` with stable ACM certificate
2. Generate SPKI hashes using openssl
3. Configure `NSPinnedDomains` in Info.plist

**Pinning configuration (in Info.plist comment block):**
```xml
<key>NSPinnedDomains</key>
<dict>
    <key>api.vettid.dev</key>
    <dict>
        <key>NSIncludesSubdomains</key>
        <true/>
        <key>NSPinnedCAIdentities</key>
        <array>
            <dict>
                <key>SPKI-SHA256-BASE64</key>
                <string>YOUR_PIN_HASH_HERE</string>
            </dict>
        </array>
    </dict>
</dict>
```

**Generate SPKI hash:**
```bash
openssl s_client -connect api.vettid.dev:443 | \
    openssl x509 -pubkey -noout | \
    openssl pkey -pubin -outform der | \
    openssl dgst -sha256 -binary | base64
```

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

## Backend Handler Documentation

### app.bootstrap - Full NATS Credentials Exchange

**Status:** ✅ Implemented and Deployed (vault-manager `bootstrap.go`)

The `app.bootstrap` handler issues full NATS credentials and performs E2E session key exchange.

#### Request Format
```json
{
  "id": "unique-request-id",
  "type": "app.bootstrap",
  "timestamp": "2025-12-30T15:30:00Z",
  "payload": {
    "device_id": "ios-device-xyz",
    "device_type": "ios",
    "app_version": "1.0.0",
    "requested_ttl_hours": 168,
    "app_session_public_key": "base64-encoded-X25519-public-key"
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `device_id` | string | Yes | Unique device identifier |
| `device_type` | string | No | "android" or "ios" |
| `app_version` | string | No | App version for compatibility |
| `requested_ttl_hours` | int | No | Credential TTL (default: 168 = 7 days, max: 720 = 30 days) |
| `app_session_public_key` | string | No | X25519 public key (base64) for E2E encryption |

#### Response Format
```json
{
  "event_id": "unique-request-id",
  "success": true,
  "timestamp": "2025-12-30T15:30:01Z",
  "result": {
    "credentials": "-----BEGIN NATS USER JWT-----\n...",
    "nats_endpoint": "tls://nats.vettid.dev:4222",
    "owner_space": "OwnerSpace.abc123",
    "message_space": "MessageSpace.abc123",
    "topics": {
      "send_to_vault": "OwnerSpace.abc123.forVault.>",
      "receive_from_vault": "OwnerSpace.abc123.forApp.>"
    },
    "expires_at": "2026-01-06T15:30:00Z",
    "ttl_seconds": 604800,
    "credential_id": "cred-12345678",
    "rotation_info": {
      "rotate_before_hours": 24,
      "rotation_topic": "OwnerSpace.abc123.forVault.credentials.refresh"
    },
    "session_info": {
      "session_id": "sess-87654321",
      "vault_session_public_key": "base64-encoded-vault-X25519-public-key",
      "session_expires_at": "2026-01-06T15:30:00Z",
      "encryption_enabled": true
    }
  }
}
```

**Notes:**
- `session_info` is only present if `app_session_public_key` was provided in request
- `credentials` is a full NATS credentials file (JWT + seed) - replace bootstrap creds
- iOS implementation: `SessionKeyManager` + `NatsConnectionManager.performBootstrap()`

---

## Incoming Notifications (Vault → App)

Subscribe to `forApp.*` topics for real-time notifications:

| Topic | iOS Type | Description |
|-------|----------|-------------|
| `forApp.new-message` | `IncomingMessage` | New message from peer |
| `forApp.read-receipt` | `IncomingReadReceipt` | Peer read your message |
| `forApp.profile-update` | `IncomingProfileUpdate` | Profile update from peer |
| `forApp.connection-revoked` | `IncomingConnectionRevoked` | Peer revoked connection |
| `forApp.credentials.rotate` | `CredentialRotationHandler` | Vault-initiated credential rotation |

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
- [x] Start/stop vault instance (Cognito auth)
- [x] Provisioning polling
- [x] Start/stop vault via action tokens (mobile-friendly)
- [x] Background sync (BGAppRefreshTask)

### Security
- [x] HTTPS only (ATS)
- [x] TLS 1.2+ enforced
- [x] Perfect Forward Secrecy required
- [x] Request signing (HMAC-SHA256)
- [x] Replay protection (nonce + timestamp)
- [x] Request ID tracking
- [x] Certificate pinning config prepared
- [ ] Certificate pinning enabled (requires custom domain)

### Pending
- [x] Subscribe to `forApp.credentials.rotate` for proactive rotation
- [x] Implement credential rotation handler
- [ ] Add swift-sodium for native Argon2id
- [ ] Add nats.swift for production NATS connectivity

---

## Known Differences from Android

| Feature | Android | iOS |
|---------|---------|-----|
| NATS Library | `nats.java` | Stub wrapper (pending `nats.swift`) |
| Argon2id | `argon2-jvm` | PBKDF2 fallback (pending `swift-sodium`) |
| Background Sync | WorkManager | BGAppRefreshTask ✅ |
| Keystore | Android Keystore | iOS Keychain |
| Attestation | SafetyNet/Play Integrity | App Attest |
| Cert Pinning Config | `network_security_config.xml` | `Info.plist` NSPinnedDomains |
| API Security | `ApiSecurity.kt` | `ApiSecurity.swift` |

### Security Parity

Both platforms have matching security implementations:

| Security Feature | Android | iOS |
|-----------------|---------|-----|
| HTTPS Only | ✅ `cleartextTrafficPermitted="false"` | ✅ ATS enabled |
| TLS 1.2+ | ✅ Default | ✅ Default |
| Cert Pinning | ⏸️ Commented out | ⏸️ Commented out |
| Request Signing | ✅ `ApiSecurity.signRequest()` | ✅ `ApiSecurity.signRequest()` |
| Replay Protection | ✅ Nonce + timestamp | ✅ Nonce + timestamp |
| Request IDs | ✅ `X-VettID-Request-ID` | ✅ `X-VettID-Request-ID` |

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

**Response Topic Pattern:**
```
Request:  OwnerSpace.{guid}.forVault.{eventType}
Response: OwnerSpace.{guid}.forApp.{eventType}.{requestId}
```

Example for `app.bootstrap`:
```
Request:  OwnerSpace.abc123.forVault.app.bootstrap
Response: OwnerSpace.abc123.forApp.app.bootstrap.req-12345
```

The app subscribes with wildcard `forApp.app.bootstrap.>` to receive responses.

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
