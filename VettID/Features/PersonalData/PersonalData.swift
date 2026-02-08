import Foundation

// MARK: - Data Category (6 categories)

enum DataCategory: String, Codable, CaseIterable {
    case identity = "identity"
    case contact = "contact"
    case address = "address"
    case financial = "financial"
    case medical = "medical"
    case other = "other"

    var displayName: String {
        switch self {
        case .identity: return "Identity"
        case .contact: return "Contact"
        case .address: return "Address"
        case .financial: return "Financial"
        case .medical: return "Medical"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .identity: return "person.fill"
        case .contact: return "phone.fill"
        case .address: return "location.fill"
        case .financial: return "building.columns.fill"
        case .medical: return "cross.case.fill"
        case .other: return "square.grid.2x2.fill"
        }
    }

    var description: String {
        switch self {
        case .identity: return "Personal identification information"
        case .contact: return "Phone, email, and social accounts"
        case .address: return "Physical and mailing addresses"
        case .financial: return "Banking and financial details"
        case .medical: return "Health and medical information"
        case .other: return "Miscellaneous personal data"
        }
    }

    /// Display order for grouped views
    var sortIndex: Int {
        switch self {
        case .identity: return 0
        case .contact: return 1
        case .address: return 2
        case .financial: return 3
        case .medical: return 4
        case .other: return 5
        }
    }
}

// MARK: - Data Type

enum DataType: String, Codable {
    case `public` = "public"
    case `private` = "private"
    case key = "key"
    case minorSecret = "minor_secret"

    var displayName: String {
        switch self {
        case .public: return "Public"
        case .private: return "Private"
        case .key: return "Key"
        case .minorSecret: return "Minor Secret"
        }
    }

    var description: String {
        switch self {
        case .public: return "Shared with all connections"
        case .private: return "Shared only with consent"
        case .key: return "Cryptographic keys"
        case .minorSecret: return "Never shared"
        }
    }
}

// MARK: - Field Type

enum FieldType: String, Codable, CaseIterable {
    case text = "text"
    case password = "password"
    case number = "number"
    case date = "date"
    case email = "email"
    case phone = "phone"
    case url = "url"
    case note = "note"

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .password: return "Password"
        case .number: return "Number"
        case .date: return "Date"
        case .email: return "Email"
        case .phone: return "Phone"
        case .url: return "URL"
        case .note: return "Note"
        }
    }
}

// MARK: - Personal Data Item

struct PersonalDataItem: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var type: DataType
    var value: String
    var category: DataCategory
    var fieldType: FieldType
    var isSystemField: Bool
    var isInPublicProfile: Bool
    var isSensitive: Bool
    var sortOrder: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        type: DataType = .private,
        value: String = "",
        category: DataCategory = .other,
        fieldType: FieldType = .text,
        isSystemField: Bool = false,
        isInPublicProfile: Bool = false,
        isSensitive: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.value = value
        self.category = category
        self.fieldType = fieldType
        self.isSystemField = isSystemField
        self.isInPublicProfile = isInPublicProfile
        self.isSensitive = isSensitive
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Grouped By Category Helper

extension Array where Element == PersonalDataItem {
    /// Returns items grouped by category in display order
    func groupedByCategory() -> [(category: DataCategory, items: [PersonalDataItem])] {
        let grouped = Dictionary(grouping: self) { $0.category }
        return DataCategory.allCases
            .compactMap { category in
                guard let items = grouped[category], !items.isEmpty else { return nil }
                return (category: category, items: items.sorted { $0.sortOrder < $1.sortOrder })
            }
    }
}

// MARK: - PersonalData View Model Events/Effects

enum PersonalDataEvent {
    case loadData
    case addItem(PersonalDataItem)
    case updateItem(PersonalDataItem)
    case deleteItem(String)
    case togglePublicProfile(String)
    case moveUp(String)
    case moveDown(String)
    case search(String)
    case syncToVault
}

enum PersonalDataEffect {
    case dataLoaded([PersonalDataItem])
    case itemAdded(PersonalDataItem)
    case itemUpdated(PersonalDataItem)
    case itemDeleted(String)
    case error(String)
    case syncComplete
}

// MARK: - Personal Data Field Input Hint

enum PersonalDataFieldInputHint: String, Codable {
    case text = "text"
    case date = "date"
    case expiryDate = "expiry_date"
    case country = "country"
    case state = "state"
    case number = "number"
    case phone = "phone"
    case email = "email"
}

// MARK: - Mock Data

extension PersonalDataItem {
    static func mockData() -> [PersonalDataItem] {
        [
            PersonalDataItem(
                name: "First Name",
                type: .public,
                value: "John",
                category: .identity,
                isSystemField: true,
                isInPublicProfile: true,
                sortOrder: 0,
                createdAt: Date().addingTimeInterval(-86400 * 60),
                updatedAt: Date().addingTimeInterval(-86400 * 7)
            ),
            PersonalDataItem(
                name: "Last Name",
                type: .public,
                value: "Doe",
                category: .identity,
                isSystemField: true,
                isInPublicProfile: true,
                sortOrder: 1,
                createdAt: Date().addingTimeInterval(-86400 * 60),
                updatedAt: Date().addingTimeInterval(-86400 * 7)
            ),
            PersonalDataItem(
                name: "Email",
                type: .public,
                value: "john.doe@example.com",
                category: .contact,
                fieldType: .email,
                isSystemField: true,
                isInPublicProfile: true,
                sortOrder: 0,
                createdAt: Date().addingTimeInterval(-86400 * 60),
                updatedAt: Date().addingTimeInterval(-86400 * 30)
            ),
            PersonalDataItem(
                name: "Phone",
                type: .private,
                value: "+1 (555) 123-4567",
                category: .contact,
                fieldType: .phone,
                sortOrder: 1,
                createdAt: Date().addingTimeInterval(-86400 * 30),
                updatedAt: Date().addingTimeInterval(-86400 * 14)
            ),
            PersonalDataItem(
                name: "Date of Birth",
                type: .private,
                value: "01/15/1990",
                category: .identity,
                fieldType: .date,
                isSensitive: true,
                sortOrder: 2,
                createdAt: Date().addingTimeInterval(-86400 * 60),
                updatedAt: Date().addingTimeInterval(-86400 * 60)
            ),
            PersonalDataItem(
                name: "Street Address",
                type: .private,
                value: "123 Main St",
                category: .address,
                sortOrder: 0,
                createdAt: Date().addingTimeInterval(-86400 * 30),
                updatedAt: Date().addingTimeInterval(-86400 * 14)
            ),
            PersonalDataItem(
                name: "City",
                type: .private,
                value: "Springfield",
                category: .address,
                sortOrder: 1,
                createdAt: Date().addingTimeInterval(-86400 * 30),
                updatedAt: Date().addingTimeInterval(-86400 * 14)
            ),
            PersonalDataItem(
                name: "Health Insurance ID",
                type: .private,
                value: "INS-12345",
                category: .medical,
                isSensitive: true,
                sortOrder: 0,
                createdAt: Date().addingTimeInterval(-86400 * 7),
                updatedAt: Date().addingTimeInterval(-86400 * 7)
            )
        ]
    }
}
