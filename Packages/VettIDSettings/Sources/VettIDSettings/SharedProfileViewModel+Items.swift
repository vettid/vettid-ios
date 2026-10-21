import Foundation
import VettIDData

/// The `@profile` items (VAULT-MESSAGING §10.8: `data` items tagged `@profile`, at most 32): added from the Vault, taken
/// out, opened. Mirrors the items of vettid-android `SharedProfileViewModel`.
extension SharedProfileViewModel {
    /// The most items a shared profile holds (§10.8).
    public static let maxProfileItems = ItemChecks.maxProfileItems

    public func pickItem(_ show: Bool) { local.pickingItem = show }

    /// Tags a standard item `@profile` (the vault answers `limit` beyond 32).
    public func addToProfile(_ i: ItemSummary) {
        guard i.sensitivity == .data, !i.tags.contains(ItemChecks.profileTag) else { return }
        retag(i, i.tags + [ItemChecks.profileTag])
    }

    public func removeFromProfile(_ i: ItemSummary) { retag(i, i.tags.filter { $0 != ItemChecks.profileTag }) }

    private func retag(_ i: ItemSummary, _ tags: [String]) {
        guard let items else { return }
        local.itemsBusy = true
        local.pickingItem = false
        local.error = nil
        local.limit = nil
        work.launch { [weak self] in
            do {
                _ = try await items.setTags(i.itemID, version: i.version, tags: tags)
                self?.local.itemsBusy = false
            } catch {
                self?.local.itemsBusy = false
                self?.failed(error)
            }
        }
    }
}
