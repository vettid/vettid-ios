import Foundation

// The Vault's texts, continued (``ItemsStrings``).
public extension ItemsStrings {
    static var labelExpires: String { String(localized: "items_label_expires", defaultValue: "Expires", bundle: .module) }

    static var labelIssuingAuthority: String {
        String(localized: "items_label_issuing_authority", defaultValue: "Issuing authority", bundle: .module)
    }

    static var labelClasses: String { String(localized: "items_label_classes", defaultValue: "Classes", bundle: .module) }

    static var labelAddress: String { String(localized: "items_label_address", defaultValue: "Address", bundle: .module) }

    static var labelWebsite: String { String(localized: "items_label_website", defaultValue: "Website", bundle: .module) }

    static var labelUsername: String { String(localized: "items_label_username", defaultValue: "Username", bundle: .module) }

    static var labelPassword: String { String(localized: "items_label_password", defaultValue: "Password", bundle: .module) }

    static var labelOneTimeCode: String {
        String(localized: "items_label_one_time_code", defaultValue: "One-time code", bundle: .module)
    }

    static var labelNetworkName: String {
        String(localized: "items_label_network_name", defaultValue: "Network name", bundle: .module)
    }

    static var labelCardholder: String { String(localized: "items_label_cardholder", defaultValue: "Cardholder", bundle: .module) }

    static var labelSecurityCode: String {
        String(localized: "items_label_security_code", defaultValue: "Security code", bundle: .module)
    }

    static var labelPin: String { String(localized: "items_label_pin", defaultValue: "PIN", bundle: .module) }

    static var labelBank: String { String(localized: "items_label_bank", defaultValue: "Bank", bundle: .module) }

    static var labelAccountHolder: String {
        String(localized: "items_label_account_holder", defaultValue: "Account holder", bundle: .module)
    }

    static var labelIban: String { String(localized: "items_label_iban", defaultValue: "IBAN or account number", bundle: .module) }

    static var labelBic: String { String(localized: "items_label_bic", defaultValue: "BIC or routing number", bundle: .module) }

    static var labelOnlineBanking: String {
        String(localized: "items_label_online_banking", defaultValue: "Online banking", bundle: .module)
    }

    static var labelAllergies: String { String(localized: "items_label_allergies", defaultValue: "Allergies", bundle: .module) }

    static var labelReactions: String { String(localized: "items_label_reactions", defaultValue: "Reactions", bundle: .module) }

    static var labelMedications: String {
        String(localized: "items_label_medications", defaultValue: "Medications", bundle: .module)
    }

    static var labelPrescribedBy: String {
        String(localized: "items_label_prescribed_by", defaultValue: "Prescribed by", bundle: .module)
    }

    static var labelBloodType: String { String(localized: "items_label_blood_type", defaultValue: "Blood type", bundle: .module) }

    static var labelInsurer: String { String(localized: "items_label_insurer", defaultValue: "Insurer", bundle: .module) }

    static var labelPolicyNumber: String {
        String(localized: "items_label_policy_number", defaultValue: "Policy number", bundle: .module)
    }

    static var labelMemberNumber: String {
        String(localized: "items_label_member_number", defaultValue: "Member number", bundle: .module)
    }

    static var labelValidUntil: String { String(localized: "items_label_valid_until", defaultValue: "Valid until", bundle: .module) }

    static var labelPhone: String { String(localized: "items_label_phone", defaultValue: "Phone", bundle: .module) }

    static var labelMakeModel: String {
        String(localized: "items_label_make_model", defaultValue: "Make and model", bundle: .module)
    }

    static var labelRegistration: String {
        String(localized: "items_label_registration", defaultValue: "Registration", bundle: .module)
    }

    static var labelVin: String { String(localized: "items_label_vin", defaultValue: "VIN", bundle: .module) }

    static var labelInsurancePolicy: String {
        String(localized: "items_label_insurance_policy", defaultValue: "Insurance policy", bundle: .module)
    }

    static var labelNextInspection: String {
        String(localized: "items_label_next_inspection", defaultValue: "Next inspection", bundle: .module)
    }

    static var labelEmail: String { String(localized: "items_label_email", defaultValue: "Email", bundle: .module) }

    static var labelName: String { String(localized: "items_label_name", defaultValue: "Name", bundle: .module) }

    static var labelRelationship: String {
        String(localized: "items_label_relationship", defaultValue: "Relationship", bundle: .module)
    }

    static var labelText: String { String(localized: "items_label_text", defaultValue: "Text", bundle: .module) }

    static var labelWallet: String { String(localized: "items_label_wallet", defaultValue: "Wallet", bundle: .module) }

    static var labelWords: String { String(localized: "items_label_words", defaultValue: "Words", bundle: .module) }

    static var labelPassphrase: String { String(localized: "items_label_passphrase", defaultValue: "Passphrase", bundle: .module) }

    static var labelSigningKey: String {
        String(localized: "items_label_signing_key", defaultValue: "Key (Ed25519 seed, base64)", bundle: .module)
    }

    static var labelPublicKey: String { String(localized: "items_label_public_key", defaultValue: "Public key", bundle: .module) }

    static var labelService: String { String(localized: "items_label_service", defaultValue: "Service", bundle: .module) }

    static var labelCodes: String { String(localized: "items_label_codes", defaultValue: "Codes", bundle: .module) }

    static func detailKind(_ a: String, _ b: String) -> String {
        String(localized: "items_detail_kind", defaultValue: "\(a) · \(b)", bundle: .module)
    }

    static var edit: String { String(localized: "items_edit", defaultValue: "Edit", bundle: .module) }

    static var protection: String { String(localized: "items_protection", defaultValue: "Protection", bundle: .module) }

    static var delete: String { String(localized: "items_delete", defaultValue: "Delete", bundle: .module) }

    static var notes: String { String(localized: "items_notes", defaultValue: "Notes", bundle: .module) }

    static var noFields: String { String(localized: "items_no_fields", defaultValue: "No fields", bundle: .module) }

    static var hiddenValue: String { String(localized: "items_hidden_value", defaultValue: "Hidden", bundle: .module) }

    static var emptyValue: String { String(localized: "items_empty_value", defaultValue: "Not filled in", bundle: .module) }

    static var maskedValue: String { String(localized: "items_masked_value", defaultValue: "••••••••", bundle: .module) }

    static func created(_ a: String) -> String {
        String(localized: "items_created", defaultValue: "Added \(a)", bundle: .module)
    }

    static func updated(_ a: String) -> String {
        String(localized: "items_updated", defaultValue: "Changed \(a)", bundle: .module)
    }

    static var secretHiddenTitle: String {
        String(localized: "items_secret_hidden_title", defaultValue: "Secret item", bundle: .module)
    }

    static var secretHiddenBody: String {
        String(
            localized: "items_secret_hidden_body",
            defaultValue: """
                Its values are hidden. Revealing them asks for your fingerprint or screen lock and is recorded in \
                your history.
                """,
            bundle: .module
        )
    }

    static var reveal: String { String(localized: "items_reveal", defaultValue: "Reveal", bundle: .module) }

    static var revealPromptTitle: String {
        String(localized: "items_reveal_prompt_title", defaultValue: "Reveal a secret item", bundle: .module)
    }

    static var criticalHiddenTitle: String {
        String(localized: "items_critical_hidden_title", defaultValue: "Inside your Protean Credential", bundle: .module)
    }

    static var criticalHiddenBody: String {
        String(
            localized: "items_critical_hidden_body",
            defaultValue: """
                This item's values are sealed in your credential. Opening it needs your credential password.
                """,
            bundle: .module
        )
    }

    static var open: String { String(localized: "items_open", defaultValue: "Open with password", bundle: .module) }

    static var hide: String { String(localized: "items_hide", defaultValue: "Hide values", bundle: .module) }

    static func cdShowValue(_ a: String) -> String {
        String(localized: "items_cd_show_value", defaultValue: "Show \(a)", bundle: .module)
    }

    static func cdHideValue(_ a: String) -> String {
        String(localized: "items_cd_hide_value", defaultValue: "Hide \(a)", bundle: .module)
    }

    static func cdCopy(_ a: String) -> String {
        String(localized: "items_cd_copy", defaultValue: "Copy \(a)", bundle: .module)
    }

    static func cdCopyCode(_ a: String) -> String {
        String(localized: "items_cd_copy_code", defaultValue: "Copy the current code of \(a)", bundle: .module)
    }

    static func cdCopySeed(_ a: String) -> String {
        String(localized: "items_cd_copy_seed", defaultValue: "Copy the setup key of \(a)", bundle: .module)
    }

    static func otpLeft(_ a: Int) -> String {
        String(localized: "items_otp_left", defaultValue: "\(a) s", bundle: .module)
    }

    static var otpUnreadable: String {
        String(localized: "items_otp_unreadable", defaultValue: "This setup key cannot make codes", bundle: .module)
    }

    static var missingTitle: String {
        String(localized: "items_missing_title", defaultValue: "This item was deleted", bundle: .module)
    }

    static var missingBody: String {
        String(localized: "items_missing_body", defaultValue: "It is no longer in your vault", bundle: .module)
    }

    static var errorItem: String { String(localized: "items_error_item", defaultValue: "Something went wrong", bundle: .module) }

    static func deleteTitle(_ a: String) -> String {
        String(localized: "items_delete_title", defaultValue: "Delete \(a)?", bundle: .module)
    }

    static var deleteBody: String {
        String(
            localized: "items_delete_body",
            defaultValue: """
                It is removed from your vault, and connections you shared it with can no longer fetch it. This \
                cannot be undone.
                """,
            bundle: .module
        )
    }

    static var deleteBodyCritical: String {
        String(
            localized: "items_delete_body_critical",
            defaultValue: """
                It is removed from your credential for good. This cannot be undone, and it needs your credential \
                password.
                """,
            bundle: .module
        )
    }

    static var protectionTitle: String {
        String(localized: "items_protection_title", defaultValue: "How it is protected", bundle: .module)
    }

    static var leaveCriticalTitle: String {
        String(localized: "items_leave_critical_title", defaultValue: "Move it out of your credential?", bundle: .module)
    }

    static var leaveCriticalBody: String {
        String(
            localized: "items_leave_critical_body",
            defaultValue: """
                Its values will then live in your vault's storage, which your vault can read without your credential \
                password.
                """,
            bundle: .module
        )
    }

    static var leaveCriticalConfirm: String {
        String(localized: "items_leave_critical_confirm", defaultValue: "Move it", bundle: .module)
    }

    static var passwordOpenTitle: String {
        String(localized: "items_password_open_title", defaultValue: "Open a critical item", bundle: .module)
    }

    static var passwordSaveTitle: String {
        String(localized: "items_password_save_title", defaultValue: "Save a critical item", bundle: .module)
    }

    static var passwordDeleteTitle: String {
        String(localized: "items_password_delete_title", defaultValue: "Delete a critical item", bundle: .module)
    }

    static var passwordProtectionTitle: String {
        String(localized: "items_password_protection_title", defaultValue: "Change its protection", bundle: .module)
    }

    static func passwordBody(_ a: String) -> String {
        String(
            localized: "items_password_body",
            defaultValue: """
                \(a) is kept inside your Protean Credential. Enter your credential password for this one change or \
                view.
                """,
            bundle: .module
        )
    }

    static var passwordLabel: String {
        String(localized: "items_password_label", defaultValue: "Credential password", bundle: .module)
    }

    static var passwordContinue: String { String(localized: "items_password_continue", defaultValue: "Continue", bundle: .module) }

    static var passwordWrong: String {
        String(localized: "items_password_wrong", defaultValue: "That password is not right", bundle: .module)
    }

    static func passwordBackoff(_ a: Int) -> String {
        String(localized: "items_password_backoff", defaultValue: "Too many wrong passwords. Try again in \(a) s", bundle: .module)
    }

    static var passwordBackoffUndated: String {
        String(
            localized: "items_password_backoff_undated",
            defaultValue: """
                Too many wrong passwords. Wait a moment and try again
                """,
            bundle: .module
        )
    }

    static var passwordNote: String {
        String(
            localized: "items_password_note",
            defaultValue: """
                Your password is used for this operation only and is not stored on this phone.
                """,
            bundle: .module
        )
    }

    static var newTitle: String { String(localized: "items_new_title", defaultValue: "Add to vault", bundle: .module) }

    static var editTitle: String { String(localized: "items_edit_title", defaultValue: "Edit item", bundle: .module) }

    static var unnamed: String { String(localized: "items_unnamed", defaultValue: "This item", bundle: .module) }

    static var save: String { String(localized: "items_save", defaultValue: "Save", bundle: .module) }

    static var saveItem: String { String(localized: "items_save_item", defaultValue: "Save item", bundle: .module) }

    static var phoneCheck: String { String(localized: "items_phone_check", defaultValue: "Check this number", bundle: .module) }

    static var name: String { String(localized: "items_name", defaultValue: "Name", bundle: .module) }

    static var category: String { String(localized: "items_category", defaultValue: "Category", bundle: .module) }

    static var cdChooseCategory: String {
        String(localized: "items_cd_choose_category", defaultValue: "Choose a category", bundle: .module)
    }

    static var tags: String { String(localized: "items_tags", defaultValue: "Tags", bundle: .module) }

    static var tagsNote: String {
        String(
            localized: "items_tags_note",
            defaultValue: """
                Tags organise your vault and decide what you share. When you share a tag with a connection, items \
                with that tag follow that sharing rule: you are asked first, or they are shared automatically.
                """,
            bundle: .module
        )
    }

    static var tagAdd: String { String(localized: "items_tag_add", defaultValue: "Add a tag", bundle: .module) }

    static var tagHint: String {
        String(
            localized: "items_tag_hint",
            defaultValue: """
                Lowercase letters, digits, spaces, hyphens (-) and underscores (_), up to 32 characters.
                """,
            bundle: .module
        )
    }

    static func cdRemoveTag(_ a: String) -> String {
        String(localized: "items_cd_remove_tag", defaultValue: "Remove tag \(a)", bundle: .module)
    }

    static var profileChoiceNote: String {
        String(
            localized: "items_profile_choice_note",
            defaultValue: """
                Everyone you're connected with sees items with this tag.
                """,
            bundle: .module
        )
    }
}
