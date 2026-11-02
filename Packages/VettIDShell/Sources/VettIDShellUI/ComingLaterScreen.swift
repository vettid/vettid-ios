#if os(iOS)
import SwiftUI
import VettIDShell
import VettIDUI

/// A drawer destination whose screens later rows of IOS-PLAN §8 bring (Vault, History), or whose repositories the app
/// was not given: its title in the top bar, with the menu and the avatar, and a line that it is not in the iPhone app yet.
/// (Chosen; not in the spec: the iPhone app ships before these screens.)
public struct ComingLaterScreen: View {
    let destination: TopLevelDestination
    let chrome: ShellChrome

    public init(destination: TopLevelDestination, chrome: ShellChrome) {
        self.destination = destination
        self.chrome = chrome
    }

    public var body: some View {
        TopLevelScaffold(title: destination.label, chrome: chrome) {
            EmptyState(icon: destination.symbol, title: destination.label, message: ShellStrings.comingLater)
                .accessibilityIdentifier("coming_later")
        }
    }
}

public extension TopLevelDestination {
    var label: String {
        switch self {
        case .messages: ShellStrings.navMessages
        case .connections: ShellStrings.navConnections
        case .approvals: ShellStrings.navApprovals
        case .votes: ShellStrings.navVotes
        case .items: ShellStrings.navItems
        case .history: ShellStrings.navHistory
        case .settings: ShellStrings.navSettings
        case .help: ShellStrings.navHelp
        }
    }

    var symbol: VettIDSymbol {
        switch self {
        case .messages: .messages
        case .connections: .connections
        case .approvals: .approvals
        case .votes: .howToVote
        case .items: .vault
        case .history: .history
        case .settings: .settings
        case .help: .help
        }
    }

    /// The drawer's sections as rows, with [badges]' counts (vettid-android `drawerSections`: approvals waiting for a
    /// decision, conversations with unread messages, open votes not voted on). The Votes entry is there only with
    /// [votesShown]: the vault answers `vote.list` and holds a vote or a connection to connect again (no empty screen).
    @MainActor static func drawerSections(badges: [TopLevelDestination: Int] = [:], votesShown: Bool = false) -> [[DrawerItem]] {
        sections.map { group in
            group.filter { $0 != .votes || votesShown }
                .map { DrawerItem(key: $0.key, label: $0.label, icon: $0.symbol, badge: badges[$0] ?? 0) }
        }
    }
}
#endif
