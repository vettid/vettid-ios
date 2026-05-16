import Foundation
import SwiftUI
import Combine

// MARK: - Personal Data View Model

/// Reads-from-vault personal-data ViewModel.
///
/// As of Phase 0.10, the vault is the only source of truth for personal
/// data. This ViewModel publishes the `items` mirror exposed by the
/// shared `PersonalDataStore`, which:
///   - hydrates on PIN unlock (via `AppState.syncProfileFromVault`),
///   - re-hydrates on every `forApp.profile.public` snapshot from the vault
///     (multi-device edits),
///   - flushes writes vault-first and then refreshes the cache.
///
/// Local mutations (add/update/delete/toggle/move) now route through
/// `PersonalDataStore`, which calls the appropriate vault verb and
/// re-hydrates on success. Nothing is persisted on-device.
@MainActor
final class PersonalDataViewModel: ObservableObject {

    enum State {
        case loading
        case loaded
        case error(String)
    }

    @Published var state: State = .loading
    @Published var items: [PersonalDataItem] = []

    private let store: PersonalDataStore
    private var cancellables: Set<AnyCancellable> = []

    init(store: PersonalDataStore = .shared) {
        self.store = store

        // Mirror the store's items. Subscribing in `init` keeps the
        // ViewModel reactive across re-hydrates without callers needing
        // to call `loadData()` again.
        store.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] newItems in
                self?.items = newItems
            }
            .store(in: &cancellables)

        store.$isHydrated
            .receive(on: RunLoop.main)
            .sink { [weak self] hydrated in
                if hydrated { self?.state = .loaded }
            }
            .store(in: &cancellables)

        store.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] err in
                if let err = err { self?.state = .error(err) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Load Data

    /// Kick a hydrate if the cache hasn't been populated yet. Idempotent.
    /// If the store hasn't been configured (i.e. the user hasn't unlocked
    /// the vault on this launch), the call falls through and the view
    /// shows the empty state until warm-up completes.
    func loadData() async {
        if store.isHydrated {
            state = .loaded
            return
        }
        state = .loading
        do {
            try await store.hydrate()
            state = .loaded
        } catch PersonalDataStoreError.notConfigured {
            // Vault not warm yet; the warm-up path will trigger hydrate.
            state = .loaded
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Grouped Data

    var groupedItems: [(category: DataCategory, items: [PersonalDataItem])] {
        items.groupedByCategory()
    }

    // MARK: - Add Data

    func addItem(name: String,
                 value: String,
                 category: DataCategory,
                 fieldType: FieldType = .text,
                 isInPublicProfile: Bool = false) async {
        // Custom field path: namespace as `<category>.<normalized_name>`
        // matching Android's `generateNamespace`.
        let namespace = Self.generateNamespace(category: category, name: name)
        do {
            try await store.updateField(namespace: namespace, value: value)
            if isInPublicProfile {
                try await store.setFieldPublic(namespace: namespace, isPublic: true)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Update Data

    func updateItem(_ item: PersonalDataItem) async {
        do {
            try await store.updateField(namespace: item.id, value: item.value)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Delete Data

    func deleteItem(_ itemId: String) async {
        do {
            try await store.deleteField(namespace: itemId)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Toggle Public Profile

    func togglePublicProfile(_ itemId: String) async {
        guard let item = items.first(where: { $0.id == itemId }) else { return }
        do {
            try await store.setFieldPublic(namespace: item.id, isPublic: !item.isInPublicProfile)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Sort Operations

    func moveUp(_ itemId: String) async {
        await swapAdjacentSortOrder(itemId: itemId, direction: -1)
    }

    func moveDown(_ itemId: String) async {
        await swapAdjacentSortOrder(itemId: itemId, direction: 1)
    }

    private func swapAdjacentSortOrder(itemId: String, direction: Int) async {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        let category = items[index].category
        let categoryItems = items
            .filter { $0.category == category }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let catIndex = categoryItems.firstIndex(where: { $0.id == itemId }) else { return }
        let neighborIndex = catIndex + direction
        guard neighborIndex >= 0, neighborIndex < categoryItems.count else { return }

        var newOrder: [String: Int] = [:]
        for (i, it) in items.enumerated() { newOrder[it.id] = it.sortOrder == 0 ? i : it.sortOrder }
        let mySort = newOrder[itemId] ?? 0
        let neighborId = categoryItems[neighborIndex].id
        let neighborSort = newOrder[neighborId] ?? 0
        newOrder[itemId] = neighborSort
        newOrder[neighborId] = mySort

        do {
            try await store.updateSortOrder(newOrder)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Search

    func filteredItems(searchText: String) -> [PersonalDataItem] {
        if searchText.isEmpty { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.value.localizedCaseInsensitiveContains(searchText) ||
            $0.category.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Category Helpers

    func items(for category: DataCategory) -> [PersonalDataItem] {
        items.filter { $0.category == category }.sorted { $0.sortOrder < $1.sortOrder }
    }

    func isEmpty(for category: DataCategory) -> Bool {
        items(for: category).isEmpty
    }

    var totalCount: Int {
        items.count
    }

    // MARK: - Namespace helpers

    private static func generateNamespace(category: DataCategory, name: String) -> String {
        let normalized = name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        return "\(category.rawValue).\(normalized)"
    }
}
