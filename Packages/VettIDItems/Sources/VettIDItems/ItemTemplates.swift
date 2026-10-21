import Foundation
import VettIDData

/// A recommended category (VAULT-MESSAGING §10.7): its label and icon name (vettid-vault `docs/item-templates.json`).
/// Mirrors vettid-android `ItemCategory`.
public struct ItemCategory: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    /// The registry's icon name (`id-card`, `key`, …): the screens map it to a symbol.
    public let icon: String
}

/// One field a template pre-fills: its label in the app's language, a kind, and the registry's presentation hint
/// [format] (VAULT-ITEMS 0.1.2, VAULT-MESSAGING 0.23.0 §10.7): `"format": "month"` on a `date` field asks for a month and
/// a year only and stores `YYYY-MM`, as for a payment card's expiry. The hint lives in the registry and the apps; it is
/// not stored in the item and the vault never sees it. Mirrors vettid-android `TemplateField`.
public struct TemplateField: Equatable, Sendable {
    public let label: String
    public let kind: String
    public let format: String?

    /// The registry's month hint (vettid-vault `docs/item-templates.json` version 3).
    public static let formatMonth = "month"

    /// A `date` with `"format": "month"`: entered with the month picker.
    public var monthYear: Bool { kind == FieldKinds.date && format == Self.formatMonth }
}

/// A template (§10.7: templates live in the apps): it suggests the name (as the name's placeholder: nothing is pre-typed,
/// owner request 2026-10-08), and pre-fills the category, the fields (labels and kinds, values empty), suggested tags and
/// a suggested sensitivity; the member can add, remove or rename anything. [id] goes into `item.template`. Mirrors
/// vettid-android `ItemTemplate`.
public struct ItemTemplate: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let category: String
    public let sensitivity: Sensitivity
    public let tags: [String]
    public let fields: [TemplateField]

    /// The draft this template starts, the name empty: the editor shows the template's name as the placeholder and saves
    /// under it when the member leaves the name empty.
    public func draft() -> ItemDraft {
        ItemDraft(
            name: "", category: category, template: id, sensitivity: sensitivity, tags: tags,
            fields: fields.map { DraftField(label: $0.label, kind: $0.kind, monthYear: $0.monthYear) }
        )
    }
}

/// The shared registry of recommended categories and templates (vettid-vault `docs/item-templates.json`, format 1,
/// version 3), in its order. Mirrors vettid-android `ItemTemplates`.
public enum ItemTemplates {
    public static var categories: [ItemCategory] {
        [
            ItemCategory(id: "identity_document", label: ItemsStrings.categoryIdentityDocument, icon: "id-card"),
            ItemCategory(id: "login", label: ItemsStrings.categoryLogin, icon: "key"),
            ItemCategory(id: "payment_card", label: ItemsStrings.categoryPaymentCard, icon: "credit-card"),
            ItemCategory(id: "bank_account", label: ItemsStrings.categoryBankAccount, icon: "bank"),
            ItemCategory(id: "medical", label: ItemsStrings.categoryMedical, icon: "medical"),
            ItemCategory(id: "insurance", label: ItemsStrings.categoryInsurance, icon: "shield"),
            ItemCategory(id: "vehicle", label: ItemsStrings.categoryVehicle, icon: "car"),
            ItemCategory(id: "contact", label: ItemsStrings.categoryContact, icon: "person"),
            ItemCategory(id: "note", label: ItemsStrings.categoryNote, icon: "note"),
            ItemCategory(id: "crypto_wallet", label: ItemsStrings.categoryCryptoWallet, icon: "wallet"),
            ItemCategory(id: "other", label: ItemsStrings.categoryOther, icon: "folder"),
        ]
    }

    /// A recommended category, or nil for a member-defined one (§10.7 allows any `[a-z][a-z0-9_]{0,31}`).
    public static func category(_ id: String) -> ItemCategory? { categories.first { $0.id == id } }

    /// The registry's icon name of [category] (`folder` for a member-defined one).
    public static func icon(_ category: String) -> String { self.category(category)?.icon ?? "folder" }

    /// A member-defined category, as shown: `home_lab` → "Home lab".
    public static func customLabel(_ id: String) -> String { ItemCategories.humanize(id) }

    private static func f(_ label: String, _ kind: String, _ format: String? = nil) -> TemplateField {
        TemplateField(label: label, kind: kind, format: format)
    }

    // The registry's rows stay one per line, with short names for the strings and the kinds.
    // swiftlint:disable type_name line_length
    private typealias S = ItemsStrings
    private typealias K = FieldKinds

    public static var all: [ItemTemplate] { identity + money + health + contact + other }

    private static var identity: [ItemTemplate] {
        [
            ItemTemplate(
                id: "passport", name: S.templatePassport, category: "identity_document", sensitivity: .data, tags: ["identity", "travel"],
                fields: [
                    f(S.labelNumber, K.text), f(S.labelFullName, K.text), f(S.labelNationality, K.text), f(S.labelDateOfBirth, K.date),
                    f(S.labelIssued, K.date), f(S.labelExpires, K.date), f(S.labelIssuingAuthority, K.text),
                ]
            ),
            ItemTemplate(
                id: "drivers_license", name: S.templateDriversLicense, category: "identity_document", sensitivity: .data,
                tags: ["identity", "driving"],
                fields: [f(S.labelNumber, K.text), f(S.labelFullName, K.text), f(S.labelClasses, K.text), f(S.labelExpires, K.date), f(S.labelAddress, K.address)]
            ),
            ItemTemplate(
                id: "national_id", name: S.templateNationalId, category: "identity_document", sensitivity: .data, tags: ["identity"],
                fields: [f(S.labelNumber, K.text), f(S.labelFullName, K.text), f(S.labelDateOfBirth, K.date), f(S.labelExpires, K.date)]
            ),
            ItemTemplate(
                id: "login", name: S.templateLogin, category: "login", sensitivity: .secret, tags: [],
                fields: [f(S.labelWebsite, K.url), f(S.labelUsername, K.text), f(S.labelPassword, K.password), f(S.labelOneTimeCode, K.otp)]
            ),
            ItemTemplate(
                id: "wifi", name: S.templateWifi, category: "login", sensitivity: .secret, tags: ["home"],
                fields: [f(S.labelNetworkName, K.text), f(S.labelPassword, K.password)]
            ),
        ]
    }

    private static var money: [ItemTemplate] {
        [
            ItemTemplate(
                id: "payment_card", name: S.templatePaymentCard, category: "payment_card", sensitivity: .secret, tags: ["money"],
                fields: [
                    // The registry's `"format": "month"` (VAULT-ITEMS 0.1.2): a card expires in a month, stored `YYYY-MM`.
                    f(S.labelCardholder, K.text), f(S.labelNumber, K.text), f(S.labelExpires, K.date, TemplateField.formatMonth),
                    f(S.labelSecurityCode, K.password), f(S.labelPin, K.password),
                ]
            ),
            ItemTemplate(
                id: "bank_account", name: S.templateBankAccount, category: "bank_account", sensitivity: .secret, tags: ["money"],
                fields: [
                    f(S.labelBank, K.text), f(S.labelAccountHolder, K.text), f(S.labelIban, K.text), f(S.labelBic, K.text),
                    f(S.labelOnlineBanking, K.url),
                ]
            ),
        ]
    }

    private static var health: [ItemTemplate] {
        [
            ItemTemplate(
                id: "allergies", name: S.templateAllergies, category: "medical", sensitivity: .data, tags: ["medical"],
                fields: [f(S.labelAllergies, K.multiline), f(S.labelReactions, K.multiline)]
            ),
            ItemTemplate(
                id: "medications", name: S.templateMedications, category: "medical", sensitivity: .data, tags: ["medical"],
                fields: [f(S.labelMedications, K.multiline), f(S.labelPrescribedBy, K.text)]
            ),
            ItemTemplate(
                id: "blood_type", name: S.templateBloodType, category: "medical", sensitivity: .data, tags: ["medical"],
                fields: [f(S.labelBloodType, K.text)]
            ),
            ItemTemplate(
                id: "insurance_card", name: S.templateInsuranceCard, category: "insurance", sensitivity: .data, tags: ["insurance"],
                fields: [
                    f(S.labelInsurer, K.text), f(S.labelPolicyNumber, K.text), f(S.labelMemberNumber, K.text), f(S.labelValidUntil, K.date),
                    f(S.labelPhone, K.phone),
                ]
            ),
            ItemTemplate(
                id: "vehicle", name: S.templateVehicle, category: "vehicle", sensitivity: .data, tags: ["vehicle"],
                fields: [
                    f(S.labelMakeModel, K.text), f(S.labelRegistration, K.text), f(S.labelVin, K.text), f(S.labelInsurancePolicy, K.text),
                    f(S.labelNextInspection, K.date),
                ]
            ),
        ]
    }

    // Contact information is one item per contact point, so each can be shared on its own; no template adds a reserved
    // tag (VAULT-ITEMS 0.1.1, owner decision 2026-10-08).
    private static var contact: [ItemTemplate] {
        [
            ItemTemplate(
                id: "email_address", name: S.templateEmailAddress, category: "contact", sensitivity: .data, tags: [],
                fields: [f(S.labelEmail, K.email)]
            ),
            ItemTemplate(
                id: "phone_number", name: S.templatePhoneNumber, category: "contact", sensitivity: .data, tags: [],
                fields: [f(S.labelPhone, K.phone)]
            ),
            ItemTemplate(
                id: "postal_address", name: S.templatePostalAddress, category: "contact", sensitivity: .data, tags: [],
                fields: [f(S.labelAddress, K.address)]
            ),
            ItemTemplate(
                id: "website", name: S.templateWebsite, category: "contact", sensitivity: .data, tags: [], fields: [f(S.labelWebsite, K.url)]
            ),
            ItemTemplate(
                id: "emergency_contact", name: S.templateEmergencyContact, category: "contact", sensitivity: .data, tags: ["medical"],
                fields: [f(S.labelName, K.text), f(S.labelRelationship, K.text), f(S.labelPhone, K.phone)]
            ),
        ]
    }

    private static var other: [ItemTemplate] {
        [
            ItemTemplate(id: "note", name: S.templateNote, category: "note", sensitivity: .data, tags: [], fields: [f(S.labelText, K.multiline)]),
            ItemTemplate(
                id: "secure_note", name: S.templateSecureNote, category: "note", sensitivity: .secret, tags: [],
                fields: [f(S.labelText, K.multiline)]
            ),
            ItemTemplate(
                id: "recovery_phrase", name: S.templateRecoveryPhrase, category: "crypto_wallet", sensitivity: .critical, tags: ["crypto"],
                fields: [f(S.labelWallet, K.text), f(S.labelWords, K.multiline), f(S.labelPassphrase, K.password)]
            ),
            ItemTemplate(
                id: "signing_key", name: S.templateSigningKey, category: "crypto_wallet", sensitivity: .critical, tags: ["crypto"],
                fields: [f(S.labelSigningKey, K.password), f(S.labelPublicKey, K.text)]
            ),
            ItemTemplate(
                id: "recovery_codes", name: S.templateRecoveryCodes, category: "login", sensitivity: .critical, tags: [],
                fields: [f(S.labelService, K.url), f(S.labelCodes, K.multiline)]
            ),
        ]
    }

    public static func template(_ id: String) -> ItemTemplate? { all.first { $0.id == id } }

    /// A blank item: a name, in the category the member picks, and no field yet. Each field is added through "Add a
    /// field", which asks what it is called.
    public static func blank() -> ItemDraft { ItemDraft() }

    /// An item's draft with its template's entry hints (§10.7, 0.23.0): a stored `date` is a month when its value is one
    /// (`YYYY-MM`, read from the value's form by ``ItemDraft/of(_:)``) and a day otherwise, whatever the template says; an
    /// empty `date` takes the `"format": "month"` hint of its template's field of the same label.
    public static func withHints(_ d: ItemDraft) -> ItemDraft {
        guard let t = d.template.flatMap(template) else { return d }
        let months = monthLabels(t)
        guard !months.isEmpty else { return d }
        var out = d
        out.fields = d.fields.map { f in
            var c = f
            if monthHint(f.kind, f.text, f.label, months) { c.monthYear = true }
            return c
        }
        return out
    }

    /// The labels of [t]'s `date` fields with `"format": "month"`.
    public static func monthLabels(_ t: ItemTemplate) -> Set<String> { Set(t.fields.filter(\.monthYear).map(\.label)) }

    /// Whether an empty `date` field labelled [label] takes the template's month hint (a stored value decides by its form).
    public static func monthHint(_ kind: String, _ text: String, _ label: String, _ monthLabels: Set<String>) -> Bool {
        kind == FieldKinds.date && text.isEmpty && monthLabels.contains(label)
    }
}

// swiftlint:enable type_name line_length
