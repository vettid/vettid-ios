#if os(iOS)
import SwiftUI
import VettIDShell
import VettIDUI

/// A drawer destination whose screens later rows of IOS-PLAN §8 bring (Messages, Approvals, Vault,
/// History): its title in the top bar, with the menu and the avatar, and a line that it is not in the iPhone app yet.
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
        case .items: .vault
        case .history: .history
        case .settings: .settings
        case .help: .help
        }
    }

    /// The drawer's sections as rows (no counts yet: approvals and unread messages come with I2).
    @MainActor static var drawerSections: [[DrawerItem]] {
        sections.map { group in group.map { DrawerItem(key: $0.key, label: $0.label, icon: $0.symbol) } }
    }
}
#endif
