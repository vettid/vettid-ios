#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDItemsUI
import VettIDShell
import VettIDUI

/// The Vault's screens over the shell (vettid-android's `itemsDestination`): an item, "Add to vault", the add/edit screen
/// and the tags; and the tags' colour keeper the shell hosts.
extension AppShell {
    @ViewBuilder func itemsDetail(_ route: ShellRoute) -> some View {
        if let items {
            switch route {
            case .item(let id):
                ItemDetailRoute(id, items: items, host: itemsHost)
            case .newItem:
                TemplatePickerScreen(onBack: { model.pop() }, onPick: { model.replace(.itemEdit(itemID: nil, template: $0)) })
            case .itemEdit(let itemID, let template):
                ItemEditRoute(itemID: itemID, template: template, items: items, sharing: sharing, connections: connections, host: itemsHost)
            case .tags:
                if let sharing { TagsRoute(sharing: sharing) { model.pop() } }
            default:
                EmptyView()
            }
        }
    }

    /// Where the Vault's screens go (vettid-android `ItemsHost`).
    var itemsHost: ItemsHost {
        let model = model
        var h = ItemsHost()
        h.onOpenItem = { model.openItem($0) }
        h.onAdd = { model.push(.newItem) }
        h.onEdit = { model.push(.itemEdit(itemID: $0, template: $1)) }
        if sharing != nil { h.onTags = { model.push(.tags) } }
        h.onBack = { model.pop() }
        // Saved: the item's screen. An item edited from its own screen goes back to it (read again there), not twice.
        h.replaceWithItem = { id in
            if model.path.dropLast().last == .item(id) { model.pop() } else { model.replace(.item(id)) }
        }
        return h
    }

    /// The tags' colours (owner decision 2026-10-09): stored for every tag that has none, never while the daily check is
    /// due, the vault held, or locked after ten failed checks (§3.6, as vettid-android's keeper and the release update).
    func startTagColors() {
        guard tagColors == nil, let sharing else { return }
        let checks = ownerChecks
        tagColors = TagColorsKeeper(
            sharing: sharing,
            gated: { checks.lockedByOwnerCheck || checks.ownerCheck?.gated(Date()) == true },
            next: { tags in TagColors.next(tags.map { ($0.tag, $0.color) }).map { (tag: $0.0, color: $0.1) } }
        )
    }
}
#endif
