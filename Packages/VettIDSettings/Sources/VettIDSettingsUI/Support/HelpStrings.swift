import Foundation

// Help's texts, from `Resources/Localizable.xcstrings`: vettid-android's `help_` keys (`feature/settings` `strings.xml`),
// the English values the same, word for word; the `ios_help_` texts are the iPhone's own (IOS-PLAN §14, ID11 and ID18).

/// Help's texts and the website pages it opens.
enum HelpStrings {
    static var title: String {
        String(localized: "help_title", defaultValue: "Help", bundle: .module)
    }

    static var sectionLearn: String {
        String(localized: "help_section_learn", defaultValue: "Learn", bundle: .module)
    }

    static var about: String {
        String(localized: "help_about", defaultValue: "About VettID", bundle: .module)
    }

    static var security: String {
        String(localized: "help_security", defaultValue: "How VettID protects you", bundle: .module)
    }

    static var sectionSupport: String {
        String(localized: "help_section_support", defaultValue: "Support", bundle: .module)
    }

    static var contact: String {
        String(localized: "help_contact", defaultValue: "Contact us", bundle: .module)
    }

    /// IOS-PLAN ID18: the contact with Apple when the app is attested.
    static var privacy: String {
        String(localized: "ios_help_privacy", defaultValue: "Privacy", bundle: .module)
    }

    static var privacyBody: String {
        String(
            localized: "ios_help_privacy_body",
            defaultValue: """
                When you set up, move or recover a vault, your iPhone asks Apple to vouch for the VettID app. Apple learns \
                that VettID was set up on an iPhone, nothing about your vault.
                """,
            bundle: .module
        )
    }

    /// IOS-PLAN ID11: third-party keyboards refused.
    static var keyboards: String {
        String(localized: "ios_help_keyboards", defaultValue: "Keyboards", bundle: .module)
    }

    static var keyboardsBody: String {
        String(
            localized: "ios_help_keyboards_body",
            defaultValue: "VettID uses only Apple's keyboard, so that other keyboards never see your PIN, password or codes.",
            bundle: .module
        )
    }

    // The pages (vettid-android `help_url_about`, `help_url_security`, `help_url_contact`; not translated).
    static let urlAbout = "https://vettid.org/about"
    static let urlSecurity = "https://vettid.org/security"
    static let urlContact = "https://vettid.org/contact"
}
