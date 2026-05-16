import Foundation

// MARK: - Critical Secrets State Machine

enum CriticalSecretsState: Equatable {
    case passwordPrompt
    case authenticating
    case metadataList
    case secondPasswordPrompt(secretId: String)
    case retrieving(secretId: String)
    case revealed(secretId: String, value: String, countdown: Int)
    case error(String)

    static func == (lhs: CriticalSecretsState, rhs: CriticalSecretsState) -> Bool {
        switch (lhs, rhs) {
        case (.passwordPrompt, .passwordPrompt),
             (.authenticating, .authenticating),
             (.metadataList, .metadataList):
            return true
        case (.secondPasswordPrompt(let a), .secondPasswordPrompt(let b)):
            return a == b
        case (.retrieving(let a), .retrieving(let b)):
            return a == b
        case (.revealed(let aId, _, let aC), .revealed(let bId, _, let bC)):
            return aId == bId && aC == bC
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Critical Secret Metadata

struct CriticalSecretMetadata: Identifiable, Equatable {
    let id: String
    let name: String
    let category: CriticalSecretCategory
    let createdAt: Date
    let updatedAt: Date

    var icon: String { category.icon }
}

// MARK: - Critical Secret Category

enum CriticalSecretCategory: String, Codable {
    case vaultSecret = "vault_secret"
    case cryptoKey = "crypto_key"
    case credential = "credential"
    case recoveryCode = "recovery_code"

    var displayName: String {
        switch self {
        case .vaultSecret: return "Vault Secret"
        case .cryptoKey: return "Crypto Key"
        case .credential: return "Credential"
        case .recoveryCode: return "Recovery Code"
        }
    }

    var icon: String {
        switch self {
        case .vaultSecret: return "lock.shield.fill"
        case .cryptoKey: return "key.horizontal.fill"
        case .credential: return "person.badge.key.fill"
        case .recoveryCode: return "arrow.counterclockwise.circle.fill"
        }
    }
}
