import Foundation

// MARK: - Secret Model

struct Secret: Identifiable, Codable {
    let id: String
    var name: String
    var encryptedValue: String  // Base64 encoded encrypted value
    var category: SecretCategory
    var notes: String?
    let createdAt: Date
    var updatedAt: Date

    enum SecretCategory: String, Codable, CaseIterable {
        case password = "password"
        case note = "note"
        case apiKey = "api_key"
        case recoveryCode = "recovery_code"
        case pin = "pin"
        case other = "other"

        var displayName: String {
            switch self {
            case .password: return "Password"
            case .note: return "Secure Note"
            case .apiKey: return "API Key"
            case .recoveryCode: return "Recovery Code"
            case .pin: return "PIN"
            case .other: return "Other"
            }
        }

        var icon: String {
            switch self {
            case .password: return "key.fill"
            case .note: return "note.text"
            case .apiKey: return "terminal.fill"
            case .recoveryCode: return "arrow.uturn.backward.circle.fill"
            case .pin: return "number.circle.fill"
            case .other: return "lock.fill"
            }
        }
    }
}

// MARK: - Mock Data

extension Secret {
    static func mockSecrets() -> [Secret] {
        [
            Secret(
                id: UUID().uuidString,
                name: "Email Account",
                encryptedValue: "encrypted_placeholder",
                category: .password,
                notes: "Main email account",
                createdAt: Date().addingTimeInterval(-86400 * 30),
                updatedAt: Date().addingTimeInterval(-86400 * 7)
            ),
            Secret(
                id: UUID().uuidString,
                name: "GitHub API Token",
                encryptedValue: "encrypted_placeholder",
                category: .apiKey,
                notes: nil,
                createdAt: Date().addingTimeInterval(-86400 * 14),
                updatedAt: Date().addingTimeInterval(-86400 * 14)
            ),
            Secret(
                id: UUID().uuidString,
                name: "Backup Recovery Codes",
                encryptedValue: "encrypted_placeholder",
                category: .recoveryCode,
                notes: "2FA recovery codes",
                createdAt: Date().addingTimeInterval(-86400 * 60),
                updatedAt: Date().addingTimeInterval(-86400 * 60)
            ),
            Secret(
                id: UUID().uuidString,
                name: "Banking PIN",
                encryptedValue: "encrypted_placeholder",
                category: .pin,
                notes: nil,
                createdAt: Date().addingTimeInterval(-86400 * 90),
                updatedAt: Date().addingTimeInterval(-86400 * 30)
            ),
            Secret(
                id: UUID().uuidString,
                name: "Private Notes",
                encryptedValue: "encrypted_placeholder",
                category: .note,
                notes: "Personal notes",
                createdAt: Date().addingTimeInterval(-86400 * 5),
                updatedAt: Date().addingTimeInterval(-86400)
            )
        ]
    }
}
