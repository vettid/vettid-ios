# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VettID iOS application - Swift/iOS project implementing the Protean Credential System for secure vault enrollment, credential management, and vault communication.

## Build Commands

```bash
# Build the project
xcodebuild -scheme VettID -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build

# Run tests (after adding test target in Xcode)
xcodebuild -scheme VettID -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' test

# Run a single test
xcodebuild -scheme VettID -only-testing:VettIDTests/TestClassName/testMethodName test
```

## Architecture

### Core Components

- **Core/Crypto/**
  - `CryptoManager.swift` - X25519 key exchange, Ed25519 signing, ChaCha20-Poly1305 encryption
  - `PasswordHasher.swift` - Argon2id password hashing (via libsodium) with PBKDF2 fallback

- **Core/Storage/**
  - `SecureKeyStore.swift` - Keychain integration with biometric protection
  - `CredentialStore.swift` - Credential lifecycle management (LAT, UTK)

- **Core/Networking/**
  - `APIClient.swift` - HTTP client for Ledger Service API

- **Core/Attestation/**
  - `AttestationManager.swift` - App Attest for device verification

- **Features/**
  - `EnrollmentService.swift` - 3-step enrollment flow
  - `AuthenticationService.swift` - Action-based authentication with LAT verification
  - `VaultService.swift` - Vault lifecycle management

### Security Features

- X25519 ECDH key exchange for forward secrecy
- ChaCha20-Poly1305 authenticated encryption
- Ed25519 digital signatures
- Argon2id password hashing (memory-hard, GPU-resistant)
- Keychain storage with biometric access control
- App Attest device attestation
- LAT mutual authentication (anti-phishing)
- One-time Transaction Keys (UTK)

## Adding swift-sodium for Production

For production, add swift-sodium package for real Argon2id:

1. Open project in Xcode
2. File → Add Packages...
3. Add: `https://github.com/jedisct1/swift-sodium.git`
4. Select "Sodium" product

The PasswordHasher will automatically use Argon2id when Sodium is available.

## Adding Test Target

To run the unit tests in VettIDTests/:

1. Open project in Xcode
2. File → New → Target → Unit Testing Bundle
3. Name it "VettIDTests"
4. Add existing test files from VettIDTests/ to the target
5. Build and run tests

## Documentation

All design documents are maintained in the [vettid-dev repository](https://github.com/mesmerverse/vettid-dev/tree/main/docs):

- `protean_credential_system_design.md` - Complete API specification
- `vault-voting-design.md` - Vault-based voting system design
- `vault_services_architecture.md` - Vault services architecture
- `NATS-MESSAGING-ARCHITECTURE.md` - NATS messaging patterns
- `NITRO-ENCLAVE-VAULT-ARCHITECTURE.md` - Nitro Enclave architecture
