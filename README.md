# VettID iOS

VettID iOS mobile application for secure credential management and vault access.

## Requirements

- iOS 16.0+
- Xcode 15.0+
- Swift 5.9+

## Features

- Protean Credential enrollment via QR code
- Secure credential storage using iOS Keychain
- Hardware Key Attestation (App Attest)
- Vault deployment and management
- Biometric authentication (Face ID / Touch ID)
- X25519 key exchange + XChaCha20-Poly1305 encryption

## Project Structure

```
VettID/
├── App/
│   ├── VettIDApp.swift          # App entry point
│   └── ContentView.swift        # Root view
├── Features/
│   ├── Enrollment/              # QR scanning, credential setup
│   ├── Authentication/          # Login, biometrics
│   ├── Vault/                   # Vault status, commands
│   └── Settings/                # User preferences
├── Core/
│   ├── Crypto/                  # X25519, Ed25519, encryption
│   ├── Networking/              # API client
│   ├── Storage/                 # Keychain, secure storage
│   └── Attestation/             # App Attest integration
└── Resources/
    └── Assets.xcassets
```

## Setup

1. Clone the repository
2. Open `VettID.xcodeproj` in Xcode
3. Configure signing & capabilities
4. Build and run

## Security

- All cryptographic keys stored in iOS Secure Enclave where available
- Keychain storage with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- App Attest for device integrity verification
- No sensitive data in UserDefaults or plain files
