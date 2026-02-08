import Foundation

// MARK: - Guide ID

enum GuideId: String, CaseIterable, Identifiable {
    case welcome
    case navigation
    case settings
    case personalData = "personal_data"
    case secrets
    case criticalSecrets = "critical_secrets"
    case voting
    case connections
    case archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome to VettID"
        case .navigation: return "Navigating the App"
        case .settings: return "App Settings"
        case .personalData: return "Personal Data"
        case .secrets: return "Managing Secrets"
        case .criticalSecrets: return "Critical Secrets"
        case .voting: return "Voting on Proposals"
        case .connections: return "Connections"
        case .archive: return "Archive"
        }
    }

    var icon: String {
        switch self {
        case .welcome: return "hand.wave"
        case .navigation: return "map"
        case .settings: return "gearshape"
        case .personalData: return "folder"
        case .secrets: return "lock.shield"
        case .criticalSecrets: return "exclamationmark.lock"
        case .voting: return "checkmark.square"
        case .connections: return "person.2"
        case .archive: return "archivebox"
        }
    }

    var priority: Int {
        switch self {
        case .welcome: return 0
        case .navigation: return 1
        case .connections: return 2
        case .personalData: return 3
        case .secrets: return 4
        case .criticalSecrets: return 5
        case .voting: return 6
        case .settings: return 7
        case .archive: return 8
        }
    }
}

// MARK: - Guide Catalog

struct GuideCatalog {
    static let allGuides: [GuideId] = GuideId.allCases.sorted { $0.priority < $1.priority }

    static func guide(for id: GuideId) -> GuideContent {
        GuideContentProvider.content(for: id)
    }
}
