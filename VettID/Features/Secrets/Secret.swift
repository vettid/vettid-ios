import Foundation

// MARK: - Secret Category

enum SecretCategory: String, Codable, CaseIterable {
    case identity = "identity"
    case cryptocurrency = "cryptocurrency"
    case bankAccount = "bank_account"
    case creditCard = "credit_card"
    case insurance = "insurance"
    case driversLicense = "drivers_license"
    case passport = "passport"
    case ssn = "ssn"
    case apiKey = "api_key"
    case password = "password"
    case wifi = "wifi"
    case certificate = "certificate"
    case note = "note"
    case totp = "totp"
    case vpn = "vpn"
    case ssh = "ssh"
    case vehicle = "vehicle"
    case loyalty = "loyalty"
    case tax = "tax"
    case other = "other"

    var displayName: String {
        switch self {
        case .identity: return "Identity"
        case .cryptocurrency: return "Cryptocurrency"
        case .bankAccount: return "Bank Account"
        case .creditCard: return "Credit Card"
        case .insurance: return "Insurance"
        case .driversLicense: return "Driver's License"
        case .passport: return "Passport"
        case .ssn: return "Social Security"
        case .apiKey: return "API Key"
        case .password: return "Password"
        case .wifi: return "WiFi"
        case .certificate: return "Certificate"
        case .note: return "Note"
        case .totp: return "TOTP Token"
        case .vpn: return "VPN"
        case .ssh: return "SSH Key"
        case .vehicle: return "Vehicle"
        case .loyalty: return "Loyalty Card"
        case .tax: return "Tax ID"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .identity: return "person.text.rectangle"
        case .cryptocurrency: return "bitcoinsign.circle.fill"
        case .bankAccount: return "building.columns.fill"
        case .creditCard: return "creditcard.fill"
        case .insurance: return "shield.checkered"
        case .driversLicense: return "car.fill"
        case .passport: return "airplane"
        case .ssn: return "number.square.fill"
        case .apiKey: return "terminal.fill"
        case .password: return "key.fill"
        case .wifi: return "wifi"
        case .certificate: return "doc.badge.ellipsis"
        case .note: return "note.text"
        case .totp: return "clock.badge.checkmark"
        case .vpn: return "network.badge.shield.half.filled"
        case .ssh: return "terminal"
        case .vehicle: return "car.side"
        case .loyalty: return "giftcard"
        case .tax: return "doc.text.fill"
        case .other: return "lock.fill"
        }
    }
}

// MARK: - Secret Type

enum SecretType: String, Codable, CaseIterable {
    case publicKey = "public_key"
    case privateKey = "private_key"
    case token = "token"
    case password = "password"
    case pin = "pin"
    case accountNumber = "account_number"
    case seedPhrase = "seed_phrase"
    case text = "text"

    var displayName: String {
        switch self {
        case .publicKey: return "Public Key"
        case .privateKey: return "Private Key"
        case .token: return "Token"
        case .password: return "Password"
        case .pin: return "PIN"
        case .accountNumber: return "Account Number"
        case .seedPhrase: return "Seed Phrase"
        case .text: return "Text"
        }
    }
}

// MARK: - Secret Sync Status

enum SecretSyncStatus: String, Codable {
    case pending = "pending"
    case synced = "synced"
    case conflict = "conflict"
    case error = "error"
}

// MARK: - Secret Field (for template-based secrets)

struct SecretField: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var value: String
    var type: SecretType
    var placeholder: String
    var inputHint: FieldInputHint

    init(id: String = UUID().uuidString, name: String, value: String = "", type: SecretType = .text, placeholder: String = "", inputHint: FieldInputHint = .text) {
        self.id = id
        self.name = name
        self.value = value
        self.type = type
        self.placeholder = placeholder
        self.inputHint = inputHint
    }
}

// MARK: - Field Input Hint

enum FieldInputHint: String, Codable {
    case text = "text"
    case date = "date"
    case expiryDate = "expiry_date"
    case country = "country"
    case state = "state"
    case number = "number"
    case password = "password"
    case pin = "pin"
}

// MARK: - Minor Secret (the primary secret model)

struct MinorSecret: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    /// Short user-set label that disambiguates similar secrets (Phase 2.3).
    /// Matches Android `MinorSecret.alias`. Shown as the second line in
    /// the catalog/list rows and used by the catalog dialog to group
    /// secrets that share an alias (e.g. "Trading Wallet" bundling
    /// several keys). Vault is authoritative.
    var alias: String?
    var value: String
    var category: SecretCategory
    var type: SecretType
    var notes: String?
    var fields: [SecretField]
    var isShareable: Bool
    var isInPublicProfile: Bool
    var isSystemField: Bool
    var sortOrder: Int
    /// DEPRECATED (Phase 2.1): the vault is authoritative now, so a
    /// per-record sync status is meaningless. Kept on the model for
    /// backwards compat with serialized older records — new records
    /// always set `.synced`. Will be removed in a follow-up pass once
    /// no consumers read it.
    var syncStatus: SecretSyncStatus
    var groupId: String?
    var groupLabel: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        alias: String? = nil,
        value: String = "",
        category: SecretCategory = .other,
        type: SecretType = .text,
        notes: String? = nil,
        fields: [SecretField] = [],
        isShareable: Bool = false,
        isInPublicProfile: Bool = false,
        isSystemField: Bool = false,
        sortOrder: Int = 0,
        syncStatus: SecretSyncStatus = .synced,
        groupId: String? = nil,
        groupLabel: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.alias = alias
        self.value = value
        self.category = category
        self.type = type
        self.notes = notes
        self.fields = fields
        self.isShareable = isShareable
        self.isInPublicProfile = isInPublicProfile
        self.isSystemField = isSystemField
        self.sortOrder = sortOrder
        self.syncStatus = syncStatus
        self.groupId = groupId
        self.groupLabel = groupLabel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Build a MinorSecret from a `secret.list` row (vault dict shape).
    /// Returns nil if required keys are missing. Phase 2.1 wire-decoder.
    static func from(vaultDict dict: [String: Any]) -> MinorSecret? {
        guard let id = dict["id"] as? String,
              let name = (dict["label"] ?? dict["name"]) as? String else {
            return nil
        }
        let categoryRaw = (dict["category"] as? String) ?? "other"
        let category = SecretCategory(rawValue: categoryRaw) ?? .other
        let typeRaw = (dict["type"] as? String) ?? "text"
        let type = SecretType(rawValue: typeRaw) ?? .text
        let visibility = (dict["visibility"] as? String) ?? "PRIVATE"
        let createdAtSeconds = (dict["created_at"] as? Double)
            ?? (dict["created_at"] as? Int).map(Double.init)
            ?? 0
        let updatedAtSeconds = (dict["updated_at"] as? Double)
            ?? (dict["updated_at"] as? Int).map(Double.init)
            ?? createdAtSeconds
        return MinorSecret(
            id: id,
            name: name,
            alias: dict["alias"] as? String,
            // `secret.list` returns metadata only; values come on demand
            // via `secret.get` (vault). Leave value empty so the UI's
            // reveal path fetches it.
            value: "",
            category: category,
            type: type,
            notes: dict["notes"] as? String,
            fields: [],
            isShareable: visibility == "PROFILE" || visibility == "CATALOG",
            isInPublicProfile: visibility == "PROFILE",
            isSystemField: false,
            sortOrder: (dict["sort_order"] as? Int) ?? 0,
            syncStatus: .synced,
            groupId: dict["group_id"] as? String,
            groupLabel: dict["group_label"] as? String,
            createdAt: createdAtSeconds > 0 ? Date(timeIntervalSince1970: createdAtSeconds) : Date(),
            updatedAt: updatedAtSeconds > 0 ? Date(timeIntervalSince1970: updatedAtSeconds) : Date()
        )
    }
}

// MARK: - Backward Compatibility Alias

typealias Secret = MinorSecret

// MARK: - Mock Data

extension MinorSecret {
    static func mockSecrets() -> [MinorSecret] {
        [
            MinorSecret(
                name: "Email Account",
                value: "encrypted_placeholder",
                category: .password,
                type: .password,
                notes: "Main email account",
                sortOrder: 0,
                createdAt: Date().addingTimeInterval(-86400 * 30),
                updatedAt: Date().addingTimeInterval(-86400 * 7)
            ),
            MinorSecret(
                name: "GitHub API Token",
                value: "encrypted_placeholder",
                category: .apiKey,
                type: .token,
                sortOrder: 1,
                createdAt: Date().addingTimeInterval(-86400 * 14),
                updatedAt: Date().addingTimeInterval(-86400 * 14)
            ),
            MinorSecret(
                name: "Bitcoin Wallet",
                value: "encrypted_placeholder",
                category: .cryptocurrency,
                type: .seedPhrase,
                notes: "Hardware wallet backup",
                sortOrder: 2,
                createdAt: Date().addingTimeInterval(-86400 * 60),
                updatedAt: Date().addingTimeInterval(-86400 * 60)
            ),
            MinorSecret(
                name: "Banking PIN",
                value: "encrypted_placeholder",
                category: .bankAccount,
                type: .pin,
                sortOrder: 3,
                createdAt: Date().addingTimeInterval(-86400 * 90),
                updatedAt: Date().addingTimeInterval(-86400 * 30)
            ),
            MinorSecret(
                name: "Identity Public Key",
                value: "ed25519_public_key_placeholder",
                category: .identity,
                type: .publicKey,
                isInPublicProfile: true,
                isSystemField: true,
                sortOrder: 0,
                syncStatus: .synced,
                createdAt: Date().addingTimeInterval(-86400 * 90),
                updatedAt: Date().addingTimeInterval(-86400 * 90)
            )
        ]
    }
}
