import Foundation

// MARK: - Personal Data Template Field

struct PersonalDataTemplateField {
    let name: String
    let namespace: String
    let category: DataCategory
    let placeholder: String
    let inputHint: PersonalDataFieldInputHint

    init(name: String, namespace: String, category: DataCategory, placeholder: String = "", inputHint: PersonalDataFieldInputHint = .text) {
        self.name = name
        self.namespace = namespace
        self.category = category
        self.placeholder = placeholder
        self.inputHint = inputHint
    }
}

// MARK: - Multi-Field Template

struct PersonalDataMultiTemplate: Identifiable {
    let id = UUID().uuidString
    let name: String
    let description: String
    let category: DataCategory
    let iconName: String
    let fields: [PersonalDataTemplateField]
}

// MARK: - Pre-defined Multi-Field Templates

extension PersonalDataMultiTemplate {
    static let homeAddress = PersonalDataMultiTemplate(
        name: "Home Address",
        description: "Add your home address",
        category: .address,
        iconName: "house.fill",
        fields: [
            PersonalDataTemplateField(name: "Street", namespace: "address.home.street", category: .address, placeholder: "Street address"),
            PersonalDataTemplateField(name: "Street 2", namespace: "address.home.street2", category: .address, placeholder: "Apt, suite, etc."),
            PersonalDataTemplateField(name: "City", namespace: "address.home.city", category: .address, placeholder: "City"),
            PersonalDataTemplateField(name: "State", namespace: "address.home.state", category: .address, placeholder: "State", inputHint: .state),
            PersonalDataTemplateField(name: "Postal Code", namespace: "address.home.postal_code", category: .address, placeholder: "ZIP code", inputHint: .number),
            PersonalDataTemplateField(name: "Country", namespace: "address.home.country", category: .address, placeholder: "Country", inputHint: .country)
        ]
    )

    static let businessAddress = PersonalDataMultiTemplate(
        name: "Business Address",
        description: "Add your business address",
        category: .address,
        iconName: "building.2.fill",
        fields: [
            PersonalDataTemplateField(name: "Company", namespace: "address.business.company", category: .address, placeholder: "Company name"),
            PersonalDataTemplateField(name: "Street", namespace: "address.business.street", category: .address, placeholder: "Street address"),
            PersonalDataTemplateField(name: "Street 2", namespace: "address.business.street2", category: .address, placeholder: "Suite, floor, etc."),
            PersonalDataTemplateField(name: "City", namespace: "address.business.city", category: .address, placeholder: "City"),
            PersonalDataTemplateField(name: "State", namespace: "address.business.state", category: .address, placeholder: "State", inputHint: .state),
            PersonalDataTemplateField(name: "Postal Code", namespace: "address.business.postal_code", category: .address, placeholder: "ZIP code", inputHint: .number),
            PersonalDataTemplateField(name: "Country", namespace: "address.business.country", category: .address, placeholder: "Country", inputHint: .country)
        ]
    )

    static let familyMember = PersonalDataMultiTemplate(
        name: "Family Member",
        description: "Add a family member's information",
        category: .identity,
        iconName: "person.2.fill",
        fields: [
            PersonalDataTemplateField(name: "Relationship", namespace: "family.relationship", category: .identity, placeholder: "e.g. Spouse, Parent"),
            PersonalDataTemplateField(name: "Full Name", namespace: "family.name", category: .identity, placeholder: "Full name"),
            PersonalDataTemplateField(name: "Phone", namespace: "family.phone", category: .contact, placeholder: "Phone number", inputHint: .phone),
            PersonalDataTemplateField(name: "Date of Birth", namespace: "family.dob", category: .identity, placeholder: "MM/DD/YYYY", inputHint: .date)
        ]
    )

    static let emergencyContact = PersonalDataMultiTemplate(
        name: "Emergency Contact",
        description: "Add an emergency contact",
        category: .contact,
        iconName: "phone.badge.plus",
        fields: [
            PersonalDataTemplateField(name: "Name", namespace: "emergency.name", category: .contact, placeholder: "Contact name"),
            PersonalDataTemplateField(name: "Phone", namespace: "emergency.phone", category: .contact, placeholder: "Phone number", inputHint: .phone),
            PersonalDataTemplateField(name: "Relationship", namespace: "emergency.relationship", category: .contact, placeholder: "e.g. Spouse, Parent")
        ]
    )

    static let fullName = PersonalDataMultiTemplate(
        name: "Full Name",
        description: "Add your full legal name",
        category: .identity,
        iconName: "person.text.rectangle",
        fields: [
            PersonalDataTemplateField(name: "Prefix", namespace: "personal.legal.prefix", category: .identity, placeholder: "e.g. Mr., Mrs., Dr."),
            PersonalDataTemplateField(name: "First Name", namespace: "personal.legal.first_name", category: .identity, placeholder: "First name"),
            PersonalDataTemplateField(name: "Middle Name", namespace: "personal.legal.middle_name", category: .identity, placeholder: "Middle name"),
            PersonalDataTemplateField(name: "Last Name", namespace: "personal.legal.last_name", category: .identity, placeholder: "Last name"),
            PersonalDataTemplateField(name: "Suffix", namespace: "personal.legal.suffix", category: .identity, placeholder: "e.g. Jr., III")
        ]
    )

    static let governmentID = PersonalDataMultiTemplate(
        name: "Government ID",
        description: "Add government identification details",
        category: .identity,
        iconName: "doc.text.fill",
        fields: [
            PersonalDataTemplateField(name: "ID Type", namespace: "gov_id.type", category: .identity, placeholder: "e.g. State ID, Military ID"),
            PersonalDataTemplateField(name: "ID Number", namespace: "gov_id.number", category: .identity, placeholder: "ID number", inputHint: .number),
            PersonalDataTemplateField(name: "Issuing Authority", namespace: "gov_id.issuer", category: .identity, placeholder: "Issuing state/agency"),
            PersonalDataTemplateField(name: "Expiration Date", namespace: "gov_id.expiry", category: .identity, placeholder: "MM/YYYY", inputHint: .expiryDate)
        ]
    )

    static let allTemplates: [PersonalDataMultiTemplate] = [
        .homeAddress, .businessAddress, .familyMember,
        .emergencyContact, .fullName, .governmentID
    ]
}

// MARK: - Single-Field Template

struct PersonalDataTemplate: Identifiable {
    let id = UUID().uuidString
    let name: String
    let namespace: String
    let category: DataCategory
    let fieldType: FieldType
    let placeholder: String
    let isSensitive: Bool

    init(name: String, namespace: String, category: DataCategory, fieldType: FieldType = .text, placeholder: String = "", isSensitive: Bool = false) {
        self.name = name
        self.namespace = namespace
        self.category = category
        self.fieldType = fieldType
        self.placeholder = placeholder
        self.isSensitive = isSensitive
    }
}

// MARK: - Pre-defined Single-Field Templates

extension PersonalDataTemplate {
    // Identity
    static let identityTemplates: [PersonalDataTemplate] = [
        PersonalDataTemplate(name: "First Name", namespace: "personal.legal.first_name", category: .identity, placeholder: "First name"),
        PersonalDataTemplate(name: "Last Name", namespace: "personal.legal.last_name", category: .identity, placeholder: "Last name"),
        PersonalDataTemplate(name: "Middle Name", namespace: "personal.legal.middle_name", category: .identity, placeholder: "Middle name"),
        PersonalDataTemplate(name: "Date of Birth", namespace: "personal.dob", category: .identity, fieldType: .date, placeholder: "MM/DD/YYYY", isSensitive: true),
        PersonalDataTemplate(name: "Gender", namespace: "personal.gender", category: .identity, placeholder: "Gender"),
        PersonalDataTemplate(name: "Nationality", namespace: "personal.nationality", category: .identity, placeholder: "Nationality"),
        PersonalDataTemplate(name: "Preferred Language", namespace: "personal.language", category: .identity, placeholder: "Language"),
        PersonalDataTemplate(name: "Nickname", namespace: "personal.nickname", category: .identity, placeholder: "Nickname")
    ]

    // Contact
    static let contactTemplates: [PersonalDataTemplate] = [
        PersonalDataTemplate(name: "Email", namespace: "contact.email", category: .contact, fieldType: .email, placeholder: "email@example.com"),
        PersonalDataTemplate(name: "Phone", namespace: "contact.phone", category: .contact, fieldType: .phone, placeholder: "+1 (555) 123-4567"),
        PersonalDataTemplate(name: "Work Email", namespace: "contact.work_email", category: .contact, fieldType: .email, placeholder: "work@example.com"),
        PersonalDataTemplate(name: "Work Phone", namespace: "contact.work_phone", category: .contact, fieldType: .phone, placeholder: "+1 (555) 987-6543"),
        PersonalDataTemplate(name: "Website", namespace: "contact.website", category: .contact, fieldType: .url, placeholder: "https://"),
        PersonalDataTemplate(name: "LinkedIn", namespace: "contact.linkedin", category: .contact, fieldType: .url, placeholder: "LinkedIn URL"),
        PersonalDataTemplate(name: "GitHub", namespace: "contact.github", category: .contact, fieldType: .url, placeholder: "GitHub username")
    ]

    // Address
    static let addressTemplates: [PersonalDataTemplate] = [
        PersonalDataTemplate(name: "Street", namespace: "address.home.street", category: .address, placeholder: "Street address"),
        PersonalDataTemplate(name: "Street 2", namespace: "address.home.street2", category: .address, placeholder: "Apt, suite, etc."),
        PersonalDataTemplate(name: "City", namespace: "address.home.city", category: .address, placeholder: "City"),
        PersonalDataTemplate(name: "State", namespace: "address.home.state", category: .address, placeholder: "State"),
        PersonalDataTemplate(name: "Postal Code", namespace: "address.home.postal_code", category: .address, fieldType: .number, placeholder: "ZIP code"),
        PersonalDataTemplate(name: "Country", namespace: "address.home.country", category: .address, placeholder: "Country"),
        PersonalDataTemplate(name: "PO Box", namespace: "address.po_box", category: .address, placeholder: "PO Box number")
    ]

    // Financial
    static let financialTemplates: [PersonalDataTemplate] = [
        PersonalDataTemplate(name: "Bank Name", namespace: "financial.bank_name", category: .financial, placeholder: "Bank name"),
        PersonalDataTemplate(name: "Account Number", namespace: "financial.account_number", category: .financial, fieldType: .number, placeholder: "Account number", isSensitive: true),
        PersonalDataTemplate(name: "Routing Number", namespace: "financial.routing_number", category: .financial, fieldType: .number, placeholder: "Routing number", isSensitive: true),
        PersonalDataTemplate(name: "Tax ID", namespace: "financial.tax_id", category: .financial, fieldType: .number, placeholder: "Tax ID number", isSensitive: true),
        PersonalDataTemplate(name: "Employer", namespace: "financial.employer", category: .financial, placeholder: "Employer name")
    ]

    // Medical
    static let medicalTemplates: [PersonalDataTemplate] = [
        PersonalDataTemplate(name: "Blood Type", namespace: "medical.blood_type", category: .medical, placeholder: "e.g. A+, O-"),
        PersonalDataTemplate(name: "Allergies", namespace: "medical.allergies", category: .medical, fieldType: .note, placeholder: "Known allergies"),
        PersonalDataTemplate(name: "Medications", namespace: "medical.medications", category: .medical, fieldType: .note, placeholder: "Current medications"),
        PersonalDataTemplate(name: "Insurance Provider", namespace: "medical.insurance_provider", category: .medical, placeholder: "Insurance company"),
        PersonalDataTemplate(name: "Insurance ID", namespace: "medical.insurance_id", category: .medical, placeholder: "Member ID", isSensitive: true),
        PersonalDataTemplate(name: "Primary Physician", namespace: "medical.physician", category: .medical, placeholder: "Doctor's name"),
        PersonalDataTemplate(name: "Emergency Notes", namespace: "medical.emergency_notes", category: .medical, fieldType: .note, placeholder: "Important medical notes"),
        PersonalDataTemplate(name: "Organ Donor", namespace: "medical.organ_donor", category: .medical, placeholder: "Yes / No")
    ]

    static let allTemplates: [PersonalDataTemplate] = identityTemplates + contactTemplates + addressTemplates + financialTemplates + medicalTemplates

    static func templates(for category: DataCategory) -> [PersonalDataTemplate] {
        switch category {
        case .identity: return identityTemplates
        case .contact: return contactTemplates
        case .address: return addressTemplates
        case .financial: return financialTemplates
        case .medical: return medicalTemplates
        case .other: return []
        }
    }
}

// MARK: - Multi-Field Template Helper

extension PersonalDataMultiTemplate {
    /// Create PersonalDataItems from this template with filled field values
    func createItems(fieldValues: [String: String]) -> [PersonalDataItem] {
        fields.enumerated().map { index, field in
            PersonalDataItem(
                name: field.name,
                type: .private,
                value: fieldValues[field.name] ?? "",
                category: field.category,
                sortOrder: index
            )
        }
    }
}
