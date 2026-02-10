# VettID iOS

Privacy-first digital identity app for iOS.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

## Overview

VettID gives you complete control over your digital identity through hardware-secured vaults. Your personal data is encrypted and stored in AWS Nitro Enclaves - even VettID cannot access your information.

## Features

- **Secure Enrollment** - QR code-based credential setup
- **Hardware Security** - Keys stored in iOS Secure Enclave
- **Biometric Auth** - Face ID and Touch ID
- **E2E Encryption** - X25519 + XChaCha20-Poly1305
- **Vault Communication** - Real-time NATS messaging
- **PCR Attestation** - Verify enclave integrity via App Attest

## Requirements

- iOS 16.0+
- Xcode 15.0+
- Swift 5.9+

## Project Structure

```
VettID/
├── Core/
│   ├── Crypto/              # X25519, Ed25519, encryption
│   ├── Storage/             # Keychain, secure storage
│   ├── Networking/          # API client
│   ├── NATS/                # NATS messaging client
│   └── Attestation/         # App Attest integration
├── Features/
│   ├── Enrollment/          # QR scanning, credential setup
│   ├── Authentication/      # Login, biometrics
│   ├── Vault/               # Vault status, commands
│   ├── Transfer/            # Credential transfer
│   └── Settings/            # User preferences
└── Resources/
    └── Assets.xcassets
```

## Build

1. Clone the repository
2. Open `VettID.xcodeproj` in Xcode
3. Configure signing & capabilities
4. Build and run

```bash
# Command line build
xcodebuild -scheme VettID -configuration Debug build

# Run tests
xcodebuild -scheme VettID test
```

## Security

- All cryptographic keys stored in iOS Secure Enclave where available
- Keychain storage with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- App Attest for device integrity verification
- No sensitive data in UserDefaults or plain files

## Related Repositories

- [vettid-dev](https://github.com/vettid/vettid-dev) - Backend infrastructure
- [vettid-android](https://github.com/vettid/vettid-android) - Android app
- [vettid-desktop](https://github.com/vettid/vettid-desktop) - Desktop app (Tauri/Rust/Svelte)
- [vettid-agent](https://github.com/vettid/vettid-agent) - Agent connector (Go sidecar)
- [vettid-service-vault](https://github.com/vettid/vettid-service-vault) - Service integration layer
- [vettid.org](https://github.com/vettid/vettid.org) - Website

## License

AGPL-3.0-or-later - See [LICENSE](LICENSE) for details.

## Links

- Website: [vettid.org](https://vettid.org)
- Documentation: [docs.vettid.dev](https://docs.vettid.dev)
