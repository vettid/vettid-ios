import SwiftUI

// MARK: - Drawer Item (Navigation Destination)
//
// The hamburger drawer that used to surface this enum is gone — the
// iOS app now matches Android's `MainScaffold`, where the user
// toggles between Connections and Vault via avatar tap / swipe and
// reaches former drawer-only destinations (Archive, Voting, Devices,
// Audit Log, Grants, Actions) through Settings instead. The enum
// itself is kept as a routing key for `MainNavigationView` and for
// deep links — switch on it and the wizard picks the right view.

enum DrawerItem: String, CaseIterable, Identifiable {
    /// Top-level destination — the connection-centric feed.
    case connections
    /// Top-level destination — segmented Data / Secrets / Wallets.
    case vault
    /// Deep-link shortcut to the Data segment of Vault.
    case personalData
    /// Deep-link shortcut to the Secrets segment.
    case secrets
    /// Deep-link shortcut to the Wallets segment.
    case wallets
    /// Archived (terminal-status) connections — reached from the feed
    /// footer and from Settings → Activity.
    case archive
    /// Voting — reached from the VettID system card's
    /// `proposalUnvoted` rows and from Settings → Activity.
    case voting
    /// Paired devices.
    case devices
    /// Vault audit log.
    case auditLog
    /// Grants subsystem inbox — pending data-share requests.
    case grants
    /// Shared-action layer (my published actions + pending invocations).
    case actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connections:  return "Connections"
        case .vault:        return "Vault"
        case .personalData: return "Personal Data"
        case .secrets:      return "Secrets"
        case .wallets:      return "Wallets"
        case .archive:      return "Archive"
        case .voting:       return "Voting"
        case .devices:      return "Devices"
        case .auditLog:     return "Audit Log"
        case .grants:       return "Grants"
        case .actions:      return "Actions"
        }
    }

    /// SF Symbols matched to the Material icons Android uses in
    /// `NavigationModels.kt` (BottomTab / VaultSegment / DrawerItem):
    ///   People         → person.2.fill
    ///   Lock           → lock.fill          (Vault tab)
    ///   Person         → person.fill        (Personal Data / Data segment)
    ///   AccountBalance → building.columns.fill (Wallets)
    ///   Security       → lock.shield        (Audit Log)
    var icon: String {
        switch self {
        case .connections:  return "person.2.fill"
        case .vault:        return "lock.fill"
        case .personalData: return "person.fill"
        case .secrets:      return "lock.fill"
        case .wallets:      return "building.columns.fill"
        case .archive:      return "archivebox.fill"
        case .voting:       return "checkmark.square.fill"
        case .devices:      return "desktopcomputer"
        case .auditLog:     return "lock.shield"
        case .grants:       return "key.fill"
        case .actions:      return "wand.and.stars"
        }
    }

    /// If this drawer item targets a sub-segment of the Vault
    /// destination, return it. Used by `MainNavigationView` to deep
    /// link from a tap into the right segmented picker position.
    var vaultSegment: VaultSegment? {
        switch self {
        case .personalData: return .data
        case .secrets:      return .secrets
        case .wallets:      return .wallets
        default:            return nil
        }
    }
}
