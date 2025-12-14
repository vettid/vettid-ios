import Foundation

// MARK: - Personal Data Model

struct PersonalData: Identifiable, Codable {
    let id: String
    var fieldName: String
    var value: String
    var category: DataCategory
    var visibility: DataVisibility
    let createdAt: Date
    var updatedAt: Date

    enum DataCategory: String, Codable, CaseIterable {
        case publicInfo = "public"
        case privateInfo = "private"
        case keys = "keys"
        case minorSecrets = "minor_secrets"

        var displayName: String {
            switch self {
            case .publicInfo: return "Public"
            case .privateInfo: return "Private"
            case .keys: return "Keys"
            case .minorSecrets: return "Minor Secrets"
            }
        }

        var icon: String {
            switch self {
            case .publicInfo: return "globe"
            case .privateInfo: return "lock.fill"
            case .keys: return "key.fill"
            case .minorSecrets: return "eye.slash.fill"
            }
        }

        var description: String {
            switch self {
            case .publicInfo: return "Information visible to your connections"
            case .privateInfo: return "Private data only you can access"
            case .keys: return "Cryptographic keys and certificates"
            case .minorSecrets: return "Less sensitive secrets"
            }
        }
    }

    enum DataVisibility: String, Codable {
        case everyone = "everyone"
        case connections = "connections"
        case selfOnly = "self_only"

        var displayName: String {
            switch self {
            case .everyone: return "Everyone"
            case .connections: return "Connections Only"
            case .selfOnly: return "Only Me"
            }
        }

        var icon: String {
            switch self {
            case .everyone: return "globe"
            case .connections: return "person.2"
            case .selfOnly: return "lock"
            }
        }
    }
}

// MARK: - Common Data Fields

struct CommonDataField {
    let fieldName: String
    let placeholder: String
    let icon: String
    let category: PersonalData.DataCategory

    static let publicFields: [CommonDataField] = [
        CommonDataField(fieldName: "Display Name", placeholder: "Your name", icon: "person.fill", category: .publicInfo),
        CommonDataField(fieldName: "Email", placeholder: "email@example.com", icon: "envelope.fill", category: .publicInfo),
        CommonDataField(fieldName: "Phone", placeholder: "+1 (555) 123-4567", icon: "phone.fill", category: .publicInfo),
        CommonDataField(fieldName: "Bio", placeholder: "Tell others about yourself", icon: "text.alignleft", category: .publicInfo)
    ]

    static let privateFields: [CommonDataField] = [
        CommonDataField(fieldName: "Date of Birth", placeholder: "MM/DD/YYYY", icon: "calendar", category: .privateInfo),
        CommonDataField(fieldName: "Address", placeholder: "Your address", icon: "house.fill", category: .privateInfo),
        CommonDataField(fieldName: "SSN", placeholder: "XXX-XX-XXXX", icon: "number", category: .privateInfo),
        CommonDataField(fieldName: "Passport Number", placeholder: "Passport #", icon: "doc.text.fill", category: .privateInfo)
    ]
}

// MARK: - Mock Data

extension PersonalData {
    static func mockData() -> [PersonalData] {
        [
            // Public info
            PersonalData(
                id: UUID().uuidString,
                fieldName: "Display Name",
                value: "John Doe",
                category: .publicInfo,
                visibility: .everyone,
                createdAt: Date().addingTimeInterval(-86400 * 60),
                updatedAt: Date().addingTimeInterval(-86400 * 7)
            ),
            PersonalData(
                id: UUID().uuidString,
                fieldName: "Email",
                value: "john.doe@example.com",
                category: .publicInfo,
                visibility: .connections,
                createdAt: Date().addingTimeInterval(-86400 * 60),
                updatedAt: Date().addingTimeInterval(-86400 * 30)
            ),

            // Private info
            PersonalData(
                id: UUID().uuidString,
                fieldName: "Date of Birth",
                value: "01/15/1990",
                category: .privateInfo,
                visibility: .selfOnly,
                createdAt: Date().addingTimeInterval(-86400 * 60),
                updatedAt: Date().addingTimeInterval(-86400 * 60)
            ),
            PersonalData(
                id: UUID().uuidString,
                fieldName: "Address",
                value: "123 Main St, City, ST 12345",
                category: .privateInfo,
                visibility: .selfOnly,
                createdAt: Date().addingTimeInterval(-86400 * 30),
                updatedAt: Date().addingTimeInterval(-86400 * 14)
            ),

            // Keys
            PersonalData(
                id: UUID().uuidString,
                fieldName: "SSH Public Key",
                value: "ssh-ed25519 AAAA...",
                category: .keys,
                visibility: .selfOnly,
                createdAt: Date().addingTimeInterval(-86400 * 14),
                updatedAt: Date().addingTimeInterval(-86400 * 14)
            ),

            // Minor secrets
            PersonalData(
                id: UUID().uuidString,
                fieldName: "Loyalty Card Number",
                value: "1234-5678-9012",
                category: .minorSecrets,
                visibility: .selfOnly,
                createdAt: Date().addingTimeInterval(-86400 * 7),
                updatedAt: Date().addingTimeInterval(-86400 * 7)
            )
        ]
    }
}
