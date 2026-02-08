import Foundation

// MARK: - Guide Content Block

enum GuideContentBlock {
    case heading(String)
    case paragraph(String)
    case bullets([String])
    case navigation(title: String, destination: GuideId)
}

// MARK: - Guide Content

struct GuideContent {
    let id: GuideId
    let title: String
    let icon: String
    let blocks: [GuideContentBlock]
}

// MARK: - Guide Content Provider

struct GuideContentProvider {
    static func content(for guide: GuideId) -> GuideContent {
        GuideContent(
            id: guide,
            title: guide.title,
            icon: guide.icon,
            blocks: blocks(for: guide)
        )
    }

    // swiftlint:disable function_body_length
    private static func blocks(for guide: GuideId) -> [GuideContentBlock] {
        switch guide {
        case .welcome:
            return [
                .heading("Welcome to VettID"),
                .paragraph("VettID is your secure digital identity vault. It helps you manage your credentials, secrets, and personal data with strong encryption and privacy controls."),
                .heading("Getting Started"),
                .bullets([
                    "Set up your profile to identify yourself to connections",
                    "Add personal data and secrets to your vault",
                    "Connect with others using secure invitations",
                    "Vote on proposals from your connections"
                ]),
                .navigation(title: "Learn about Navigation", destination: .navigation)
            ]

        case .navigation:
            return [
                .heading("Navigating VettID"),
                .paragraph("Use the bottom navigation bar to switch between main sections. Swipe the drawer from the left edge to access all features."),
                .heading("Main Sections"),
                .bullets([
                    "Feed \u{2014} See activity from your connections",
                    "Connections \u{2014} Manage your trusted contacts",
                    "Voting \u{2014} Vote on proposals",
                    "Secrets \u{2014} Store encrypted secrets",
                    "More \u{2014} Personal Data, Archive, and Settings"
                ])
            ]

        case .settings:
            return [
                .heading("App Settings"),
                .paragraph("Access settings from the gear icon in the header bar."),
                .heading("Available Settings"),
                .bullets([
                    "Theme \u{2014} Switch between light, dark, and auto themes",
                    "Security \u{2014} Configure app lock and biometric authentication",
                    "About \u{2014} View app version and diagnostics"
                ])
            ]

        case .personalData:
            return [
                .heading("Personal Data"),
                .paragraph("Store structured personal information in your vault. Data is encrypted and only accessible by you."),
                .heading("Categories"),
                .bullets([
                    "Identity \u{2014} Name, date of birth, government IDs",
                    "Contact \u{2014} Phone numbers, email addresses",
                    "Address \u{2014} Home and business addresses",
                    "Financial \u{2014} Bank accounts, payment info",
                    "Medical \u{2014} Health records, insurance info",
                    "Other \u{2014} Miscellaneous personal data"
                ]),
                .paragraph("Toggle items to include in your public profile visible to connections.")
            ]

        case .secrets:
            return [
                .heading("Managing Secrets"),
                .paragraph("Secrets are sensitive values stored with strong encryption in your vault. They are organized by category."),
                .heading("Secret Categories"),
                .bullets([
                    "Passwords and PINs",
                    "API keys and tokens",
                    "Cryptocurrency wallets and seed phrases",
                    "WiFi credentials",
                    "Notes and certificates"
                ]),
                .navigation(title: "Learn about Critical Secrets", destination: .criticalSecrets)
            ]

        case .criticalSecrets:
            return [
                .heading("Critical Secrets"),
                .paragraph("Critical secrets require additional authentication to access. They are never cached locally \u{2014} each access retrieves them directly from your vault."),
                .heading("Security Model"),
                .bullets([
                    "Password required to view metadata list",
                    "Second password required to reveal values",
                    "Values auto-hide after 30 seconds",
                    "No local caching \u{2014} always fetched fresh"
                ])
            ]

        case .voting:
            return [
                .heading("Voting on Proposals"),
                .paragraph("Your connections can submit proposals for group decisions. Cast your vote and see results in real-time."),
                .heading("How Voting Works"),
                .bullets([
                    "View active proposals in the Voting section",
                    "Cast your vote by selecting an option",
                    "See live results as votes come in",
                    "Proposals have deadlines \u{2014} vote before they close"
                ])
            ]

        case .connections:
            return [
                .heading("Connections"),
                .paragraph("Connections are your trusted contacts on VettID. All communication is end-to-end encrypted."),
                .heading("Adding Connections"),
                .bullets([
                    "Create an invitation QR code to share",
                    "Scan someone else's invitation code",
                    "Both parties must accept the connection",
                    "Messages and shared data are encrypted"
                ])
            ]

        case .archive:
            return [
                .heading("Archive"),
                .paragraph("The archive stores items that you no longer need quick access to but want to keep."),
                .heading("What Gets Archived"),
                .bullets([
                    "Closed connections",
                    "Expired credentials",
                    "Old proposals and votes",
                    "Deactivated secrets"
                ])
            ]
        }
    }
    // swiftlint:enable function_body_length
}
