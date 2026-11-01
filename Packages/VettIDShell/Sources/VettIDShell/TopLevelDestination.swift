import Foundation
import VettIDConnections

/// The drawer's destinations (ANDROID-PLAN §4 "Drawer"; IOS-PLAN ID14), in drawer order and groups: Messages,
/// Connections, Approvals, Votes | Vault, History | Settings, Help. The only top-level navigation: no tab bar. Mirrors
/// vettid-android `TopLevelDestination`.
public enum TopLevelDestination: String, CaseIterable, Sendable {
    case messages, connections, approvals
    /// Votes (IOS-PLAN §4.16), after Approvals: shown only when the vault answers `vote.list` and holds a vote or a
    /// connection to connect again (no empty screen); its badge counts open votes not yet voted on. Not in Approvals.
    case votes
    /// "Vault" in the UI; the code keeps the Items names (as vettid-android does).
    case items
    /// The member's audit log (VAULT-MESSAGING §10.9).
    case history
    case settings, help

    /// The drawer's group: hairlines between groups.
    public var group: Int {
        switch self {
        case .messages, .connections, .approvals, .votes: 0
        case .items, .history: 1
        case .settings, .help: 3
        }
    }

    /// Stable drawer key.
    public var key: String { rawValue }

    public static func fromKey(_ key: String) -> TopLevelDestination? { TopLevelDestination(rawValue: key) }

    /// The drawer's sections in order, each in drawer order.
    public static var sections: [[TopLevelDestination]] {
        Dictionary(grouping: allCases, by: \.group).sorted { $0.key < $1.key }.map(\.value)
    }

    /// Where the app opens, and where the back arrow of a top-level screen that has one (Settings) returns: vettid-android's
    /// start destination.
    public static let start = TopLevelDestination.messages

    /// Whether this destination's screen is in the iPhone app yet (IOS-PLAN §8): Messages, Connections, Approvals,
    /// Vault and History come with I2 and I3; until then a placeholder says so.
    public var available: Bool { self == .settings || self == .help }
}

/// The screens pushed over a top-level screen so far (vettid-android's routes of `feature/settings`,
/// `feature/credential`, `feature/connections`, `feature/messages`, `feature/notifications`, `feature/approvals`,
/// `feature/history` and `feature/items`).
public enum ShellRoute: Hashable, Sendable {
    case vaultStatus
    case attestation
    /// The account's name change (VAULT-MESSAGING §10.8), from the avatar sheet or the shared profile.
    case changeName
    /// The shared profile and the profile photo (VAULT-MESSAGING §10.8), from Settings → Privacy or the avatar sheet.
    case sharedProfile
    /// [fromAttempts]: from a notice about recovery attempts.
    case changePin(fromAttempts: Bool)
    case credential
    case changePassword
    /// Credential → Rotate the credential key (VAULT-MESSAGING §3.5.5), also from the offer after a change.
    case rotate
    /// The clone alarm (VAULT-MESSAGING §3.5.9), from the Credential screen or the shell's banner.
    case alarm
    /// Credential → New credential (VAULT-MESSAGING §3.5.5, `credential.reset`).
    case newCredential
    /// Settings → Security → New phone secret (release R, VAULT-MESSAGING §11.14.9).
    case newPhoneSecret
    /// Settings → Account → Delete vault (VAULT-MESSAGING §12.5).
    case deleteVault
    /// Settings → Security → Move to a new phone, the old phone's side (VAULT-MESSAGING §6.7.1).
    case transferOut
    /// Settings → Vault → "Update available" (RELEASE-UPDATES §2).
    case releaseUpdate
    /// Inviting, scanning an invitation or accepting one (VAULT-MESSAGING §6.4): from Connections' add button, or an
    /// invitation link the app was opened with.
    case connect(ConnectDestination)
    /// A connection's detail (VAULT-MESSAGING §10.4), from the Connections list, the accept screen or a conversation.
    case connection(String)
    /// A conversation with a connection (VAULT-MESSAGING §10.5), from Messages, the new-message picker, a connection's
    /// detail or the screens of connecting.
    case conversation(String)
    /// Messages' compose button: pick a connection to write to.
    case newMessage
    /// The viewer of a message's photo (VAULT-MESSAGING §10.5.1), from its bubble: only the ids travel.
    case photo(connectionID: String, messageID: String)
    /// The Notifications screen from the bell, or [archived] its Archived view (ANDROID-PLAN §4 Notifications).
    case notifications(archived: Bool)
    /// One vote by the pair (connection, proposal), never the proposal id alone (VAULT-MESSAGING 0.81.2 §10.19), from the
    /// Votes list.
    case vote(connectionID: String, proposalID: String)
    /// The votes of one service connection ("Votes from <name>"), from its page.
    case connectionVotes(String)
    /// One approval by its key (VAULT-MESSAGING §10.4, §10.12, §10.13, §6.8), from Approvals or a feed item.
    case approval(String)
    /// One History entry by its `seq` (VAULT-MESSAGING §10.9), from History or a connection's History.
    case historyEntry(Int64)
    /// One item of the Vault (VAULT-MESSAGING §10.7), from the Vault, a History entry or a feed item.
    case item(String)
    /// "Add to vault": the templates and a blank item.
    case newItem
    /// Adding ([itemID] nil, from [template] or blank) or editing an item.
    case itemEdit(itemID: String?, template: String?)
    /// The tags (VAULT-MESSAGING §10.8), from the Vault's "Manage tags".
    case tags
    /// A connection's History (ANDROID-PLAN §4 History: the connection preset), from its page.
    case connectionHistory(String)
    /// What a connection can see of the Vault: its share rules and grants (VAULT-MESSAGING §10.12, §10.13), from the
    /// connection's page.
    case connectionSharing(String)
    /// A share rule of a connection ([ruleID] nil: a new one), from its sharing screen or a feed item.
    case ruleEdit(connectionID: String, ruleID: String?)
    /// What a connection shares with the member; [ask] opens "Ask for something" at once (from the connection's page).
    case sharedWithYou(connectionID: String, ask: Bool)
}

/// This build's version as the drawer's footer shows it ("VettID 2.0.0 (1)", vettid-android `drawer_version`).
public struct AppVersion: Equatable, Sendable {
    public let name: String
    public let build: Int

    public init(name: String, build: Int) {
        self.name = name
        self.build = build
    }

    /// From an Info.plist dictionary (`CFBundleShortVersionString`, `CFBundleVersion`).
    public static func of(_ info: [String: Any]) -> AppVersion {
        AppVersion(
            name: info["CFBundleShortVersionString"] as? String ?? "",
            build: (info["CFBundleVersion"] as? String).flatMap { Int($0) } ?? 0
        )
    }
}
