import Foundation

/// The drawer's destinations (ANDROID-PLAN §4 "Drawer"; IOS-PLAN ID14), in drawer order and groups: Messages,
/// Connections, Approvals | Vault, History | Settings, Help. The only top-level navigation: no tab bar. Mirrors
/// vettid-android `TopLevelDestination`.
public enum TopLevelDestination: String, CaseIterable, Sendable {
    case messages, connections, approvals
    /// "Vault" in the UI; the code keeps the Items names (as vettid-android does).
    case items
    /// The member's audit log (VAULT-MESSAGING §10.9).
    case history
    case settings, help

    /// The drawer's group: hairlines between groups.
    public var group: Int {
        switch self {
        case .messages, .connections, .approvals: 0
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
    /// Vault and History come with I2 and I3, Help with I1.8c; until then a placeholder says so.
    public var available: Bool { self == .settings }
}

/// The screens pushed over a top-level screen so far (vettid-android's routes of `feature/settings` and
/// `feature/credential`).
public enum ShellRoute: Hashable, Sendable {
    case vaultStatus
    case attestation
    /// The account's name change (VAULT-MESSAGING §10.8), from the avatar sheet.
    case changeName
    /// [fromAttempts]: from a notice about recovery attempts.
    case changePin(fromAttempts: Bool)
    case credential
    case changePassword
    /// Settings → Security → New phone secret (release R, VAULT-MESSAGING §11.14.9).
    case newPhoneSecret
    /// Settings → Account → Delete vault (VAULT-MESSAGING §12.5).
    case deleteVault
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
