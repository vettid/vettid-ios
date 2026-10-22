import Foundation

/// The Vault's texts: vettid-android `feature/items` `strings.xml` and `strings_sharing.xml`, word for word, under their
/// string names (the whole of both in this package's table; accessors here for `strings.xml` and the tag, sharing-impact
/// and rule-name texts the screens use, the rest with the sharing screens). Android's plural `items_rule_uses` is
/// `items_rule_uses_plural` here, since one table cannot hold a string and a plural of one name (chosen; not in the
/// spec). Generated from the table; the accessors go on in the extensions of `ItemsStrings+N`.
public enum ItemsStrings {
    /// The table's bundle (for the tests' check of every key).
    public static var bundle: Bundle { .module }

    public static var title: String { String(localized: "items_title", defaultValue: "Vault", bundle: .module) }

    public static var emptyTitle: String { String(localized: "items_empty_title", defaultValue: "Your vault is empty", bundle: .module) }

    public static var emptyBody: String {
        String(
            localized: "items_empty_body",
            defaultValue: """
                Keep documents, logins and secrets in your vault, organised by tags
                """,
            bundle: .module
        )
    }

    public static var add: String { String(localized: "items_add", defaultValue: "Add to vault", bundle: .module) }

    public static var search: String { String(localized: "items_search", defaultValue: "Search by name or tag", bundle: .module) }

    public static var searchOpen: String { String(localized: "items_search_open", defaultValue: "Search your vault", bundle: .module) }

    public static var filterCategory: String { String(localized: "items_filter_category", defaultValue: "Category", bundle: .module) }

    public static var filterCategoryAny: String {
        String(localized: "items_filter_category_any", defaultValue: "Any category", bundle: .module)
    }

    public static var filterTag: String { String(localized: "items_filter_tag", defaultValue: "Tag", bundle: .module) }

    public static var filterTagAny: String { String(localized: "items_filter_tag_any", defaultValue: "Any tag", bundle: .module) }

    public static var noMatchTitle: String {
        String(localized: "items_no_match_title", defaultValue: "No items match these filters", bundle: .module)
    }

    public static var noMatchBody: String {
        String(
            localized: "items_no_match_body",
            defaultValue: """
                Change the search, or tap “✕ Clear” above to show every item
                """,
            bundle: .module
        )
    }

    public static func rowSupporting(_ a: String, _ b: String) -> String {
        String(localized: "items_row_supporting", defaultValue: "\(a) · \(b)", bundle: .module)
    }

    public static var errorList: String {
        String(localized: "items_error_list", defaultValue: "Your vault could not be read", bundle: .module)
    }

    public static var retry: String { String(localized: "items_retry", defaultValue: "Try again", bundle: .module) }

    public static var ok: String { String(localized: "items_ok", defaultValue: "OK", bundle: .module) }

    public static var cancel: String { String(localized: "items_cancel", defaultValue: "Cancel", bundle: .module) }

    public static var tagProfile: String { String(localized: "items_tag_profile", defaultValue: "Shared profile", bundle: .module) }

    public static var sensitivityData: String { String(localized: "items_sensitivity_data", defaultValue: "Standard", bundle: .module) }

    public static var sensitivitySecret: String { String(localized: "items_sensitivity_secret", defaultValue: "Secret", bundle: .module) }

    public static var sensitivityCritical: String {
        String(localized: "items_sensitivity_critical", defaultValue: "Critical", bundle: .module)
    }

    public static var sensitivityDataNote: String {
        String(localized: "items_sensitivity_data_note", defaultValue: "Shown whenever you open it", bundle: .module)
    }

    public static var sensitivitySecretNote: String {
        String(
            localized: "ios_items_sensitivity_secret_note",
            defaultValue: """
                Hidden until you reveal it with Face ID, Touch ID or your iPhone passcode; every reveal is recorded
                """,
            bundle: .module
        )
    }

    public static var sensitivityCriticalNote: String {
        String(
            localized: "items_sensitivity_critical_note",
            defaultValue: """
                Kept inside your Protean Credential: opening or changing it needs your credential password, and it \
                is never shared
                """,
            bundle: .module
        )
    }

    public static var categoryIdentityDocument: String {
        String(localized: "items_category_identity_document", defaultValue: "Identity document", bundle: .module)
    }

    public static var categoryLogin: String { String(localized: "items_category_login", defaultValue: "Login", bundle: .module) }

    public static var categoryPaymentCard: String {
        String(localized: "items_category_payment_card", defaultValue: "Payment card", bundle: .module)
    }

    public static var categoryBankAccount: String {
        String(localized: "items_category_bank_account", defaultValue: "Bank account", bundle: .module)
    }

    public static var categoryMedical: String { String(localized: "items_category_medical", defaultValue: "Medical", bundle: .module) }

    public static var categoryInsurance: String {
        String(localized: "items_category_insurance", defaultValue: "Insurance", bundle: .module)
    }

    public static var categoryVehicle: String { String(localized: "items_category_vehicle", defaultValue: "Vehicle", bundle: .module) }

    public static var categoryContact: String { String(localized: "items_category_contact", defaultValue: "Contact", bundle: .module) }

    public static var categoryNote: String { String(localized: "items_category_note", defaultValue: "Note", bundle: .module) }

    public static var categoryCryptoWallet: String {
        String(localized: "items_category_crypto_wallet", defaultValue: "Crypto wallet", bundle: .module)
    }

    public static var categoryOther: String { String(localized: "items_category_other", defaultValue: "Other", bundle: .module) }

    public static var kindText: String { String(localized: "items_kind_text", defaultValue: "Text", bundle: .module) }

    public static var kindMultiline: String { String(localized: "items_kind_multiline", defaultValue: "Long text", bundle: .module) }

    public static var kindNumber: String { String(localized: "items_kind_number", defaultValue: "Number", bundle: .module) }

    public static var kindDate: String { String(localized: "items_kind_date", defaultValue: "Date", bundle: .module) }

    public static var kindMonthYear: String { String(localized: "items_kind_month_year", defaultValue: "Month and year", bundle: .module) }

    public static var kindEmail: String { String(localized: "items_kind_email", defaultValue: "Email", bundle: .module) }

    public static var kindPhone: String { String(localized: "items_kind_phone", defaultValue: "Phone", bundle: .module) }

    public static var kindUrl: String { String(localized: "items_kind_url", defaultValue: "Web address", bundle: .module) }

    public static var kindPassword: String { String(localized: "items_kind_password", defaultValue: "Password", bundle: .module) }

    public static var kindOtp: String { String(localized: "items_kind_otp", defaultValue: "One-time code", bundle: .module) }

    public static var kindAddress: String { String(localized: "items_kind_address", defaultValue: "Address", bundle: .module) }

    public static var kindOther: String { String(localized: "items_kind_other", defaultValue: "Other", bundle: .module) }

    public static var ruleText: String {
        String(localized: "items_rule_text", defaultValue: "Remove line breaks and control characters", bundle: .module)
    }

    public static var ruleNumber: String {
        String(localized: "items_rule_number", defaultValue: "Enter a number, such as 42 or -3.5", bundle: .module)
    }

    public static var ruleDate: String {
        String(localized: "items_rule_date", defaultValue: "Enter a date as YYYY-MM-DD or YYYY-MM", bundle: .module)
    }

    public static var ruleEmail: String {
        String(localized: "items_rule_email", defaultValue: "Enter an email address, such as name@example.com", bundle: .module)
    }

    public static var rulePhone: String {
        String(localized: "items_rule_phone", defaultValue: "Use digits, spaces and + - ( ) . only", bundle: .module)
    }

    public static var ruleUrl: String {
        String(localized: "items_rule_url", defaultValue: "Enter a full web address, such as https://example.com", bundle: .module)
    }

    public static var ruleOtp: String {
        String(
            localized: "items_rule_otp",
            defaultValue: """
                Enter the setup key (16 or more letters A–Z and digits 2–7) or an otpauth:// link
                """,
            bundle: .module
        )
    }

    public static var ruleAddress: String {
        String(localized: "items_rule_address", defaultValue: "The country is a two-letter code, such as DE or US", bundle: .module)
    }

    public static var placeholderDate: String { String(localized: "items_placeholder_date", defaultValue: "YYYY-MM-DD", bundle: .module) }

    public static var placeholderMonth: String { String(localized: "items_placeholder_month", defaultValue: "YYYY-MM", bundle: .module) }

    public static var placeholderEmail: String {
        String(localized: "items_placeholder_email", defaultValue: "name@example.com", bundle: .module)
    }

    public static var placeholderPhone: String {
        String(localized: "items_placeholder_phone", defaultValue: "+44 20 7946 0000", bundle: .module)
    }

    public static var placeholderNumber: String { String(localized: "items_placeholder_number", defaultValue: "42", bundle: .module) }

    public static func cdPickDate(_ a: String) -> String {
        String(localized: "items_cd_pick_date", defaultValue: "Choose a date for \(a)", bundle: .module)
    }

    public static func cdPickMonth(_ a: String) -> String {
        String(localized: "items_cd_pick_month", defaultValue: "Choose the month and year for \(a)", bundle: .module)
    }

    public static var monthPickerTitle: String {
        String(localized: "items_month_picker_title", defaultValue: "Month and year", bundle: .module)
    }

    public static var cdPreviousYear: String { String(localized: "items_cd_previous_year", defaultValue: "Previous year", bundle: .module) }

    public static var cdNextYear: String { String(localized: "items_cd_next_year", defaultValue: "Next year", bundle: .module) }

    public static func nameDefault(_ a: String) -> String {
        String(localized: "items_name_default", defaultValue: "Left empty, it is saved as “\(a)”", bundle: .module)
    }

    public static var protectionProfile: String {
        String(
            localized: "items_protection_profile",
            defaultValue: """
                Only standard items can be in your shared profile: take it out of the shared profile to make it \
                secret or critical.
                """,
            bundle: .module
        )
    }

    public static func protectionChange(_ a: String, _ b: String) -> String {
        String(localized: "items_protection_change", defaultValue: "Changes from \(a) to \(b) when you save.", bundle: .module)
    }

    public static var savedProtectionNotTitle: String {
        String(localized: "items_saved_protection_not_title", defaultValue: "Your changes are saved", bundle: .module)
    }

    public static var savedProtectionNotBody: String {
        String(
            localized: "items_saved_protection_not_body",
            defaultValue: """
                The protection did not change. Save again to retry it.
                """,
            bundle: .module
        )
    }

    public static var placeholderUrl: String { String(localized: "items_placeholder_url", defaultValue: "https://", bundle: .module) }

    public static var placeholderOtp: String {
        String(localized: "items_placeholder_otp", defaultValue: "Setup key or otpauth:// link", bundle: .module)
    }

    public static var addTitle: String { String(localized: "items_add_title", defaultValue: "Add to vault", bundle: .module) }

    public static var templateBlank: String { String(localized: "items_template_blank", defaultValue: "Blank item", bundle: .module) }

    public static var templateBlankNote: String {
        String(localized: "items_template_blank_note", defaultValue: "Start with a name and your own fields", bundle: .module)
    }

    public static var templateNoteData: String { String(localized: "items_template_note_data", defaultValue: "Standard", bundle: .module) }

    public static var templateNoteSecret: String {
        String(localized: "items_template_note_secret", defaultValue: "Secret: hidden until you reveal it", bundle: .module)
    }

    public static var templateNoteCritical: String {
        String(localized: "items_template_note_critical", defaultValue: "Critical: inside your credential", bundle: .module)
    }

    public static var templatePassport: String { String(localized: "items_template_passport", defaultValue: "Passport", bundle: .module) }

    public static var templateDriversLicense: String {
        String(localized: "items_template_drivers_license", defaultValue: "Driver's licence", bundle: .module)
    }

    public static var templateNationalId: String {
        String(localized: "items_template_national_id", defaultValue: "National ID", bundle: .module)
    }

    public static var templateLogin: String { String(localized: "items_template_login", defaultValue: "Login", bundle: .module) }

    public static var templateWifi: String { String(localized: "items_template_wifi", defaultValue: "Wi-Fi network", bundle: .module) }

    public static var templatePaymentCard: String {
        String(localized: "items_template_payment_card", defaultValue: "Payment card", bundle: .module)
    }

    public static var templateBankAccount: String {
        String(localized: "items_template_bank_account", defaultValue: "Bank account", bundle: .module)
    }

    public static var templateAllergies: String {
        String(localized: "items_template_allergies", defaultValue: "Allergies", bundle: .module)
    }

    public static var templateMedications: String {
        String(localized: "items_template_medications", defaultValue: "Medications", bundle: .module)
    }

    public static var templateBloodType: String {
        String(localized: "items_template_blood_type", defaultValue: "Blood type", bundle: .module)
    }

    public static var templateInsuranceCard: String {
        String(localized: "items_template_insurance_card", defaultValue: "Insurance card", bundle: .module)
    }

    public static var templateVehicle: String { String(localized: "items_template_vehicle", defaultValue: "Vehicle", bundle: .module) }

    public static var templateEmailAddress: String {
        String(localized: "items_template_email_address", defaultValue: "Email address", bundle: .module)
    }

    public static var templatePhoneNumber: String {
        String(localized: "items_template_phone_number", defaultValue: "Phone number", bundle: .module)
    }

    public static var templatePostalAddress: String {
        String(localized: "items_template_postal_address", defaultValue: "Postal address", bundle: .module)
    }

    public static var templateWebsite: String { String(localized: "items_template_website", defaultValue: "Website", bundle: .module) }

    public static var templateEmergencyContact: String {
        String(localized: "items_template_emergency_contact", defaultValue: "Emergency contact", bundle: .module)
    }

    public static var templateNote: String { String(localized: "items_template_note", defaultValue: "Note", bundle: .module) }

    public static var templateSecureNote: String {
        String(localized: "items_template_secure_note", defaultValue: "Secure note", bundle: .module)
    }

    public static var templateRecoveryPhrase: String {
        String(localized: "items_template_recovery_phrase", defaultValue: "Recovery phrase", bundle: .module)
    }

    public static var templateSigningKey: String {
        String(localized: "items_template_signing_key", defaultValue: "Signing key", bundle: .module)
    }

    public static var templateRecoveryCodes: String {
        String(localized: "items_template_recovery_codes", defaultValue: "Recovery codes", bundle: .module)
    }

    public static var labelNumber: String { String(localized: "items_label_number", defaultValue: "Number", bundle: .module) }

    public static var labelFullName: String { String(localized: "items_label_full_name", defaultValue: "Full name", bundle: .module) }

    public static var labelNationality: String {
        String(localized: "items_label_nationality", defaultValue: "Nationality", bundle: .module)
    }

    public static var labelDateOfBirth: String {
        String(localized: "items_label_date_of_birth", defaultValue: "Date of birth", bundle: .module)
    }

    public static var labelIssued: String { String(localized: "items_label_issued", defaultValue: "Issued", bundle: .module) }
}
