import Foundation
import SwiftUI

// MARK: - Personal Data View Model

@MainActor
final class PersonalDataViewModel: ObservableObject {

    enum State {
        case loading
        case loaded
        case error(String)
    }

    @Published var state: State = .loading
    @Published var items: [PersonalDataItem] = []

    // MARK: - Load Data

    func loadData() async {
        state = .loading

        // Simulate loading delay
        try? await Task.sleep(nanoseconds: 500_000_000)

        items = PersonalDataItem.mockData()
        state = .loaded
    }

    // MARK: - Grouped Data

    var groupedItems: [(category: DataCategory, items: [PersonalDataItem])] {
        items.groupedByCategory()
    }

    // MARK: - Add Data

    func addItem(_ item: PersonalDataItem) {
        items.append(item)
    }

    func addItem(name: String, value: String, category: DataCategory, fieldType: FieldType = .text, isInPublicProfile: Bool = false) {
        let newItem = PersonalDataItem(
            name: name,
            type: isInPublicProfile ? .public : .private,
            value: value,
            category: category,
            fieldType: fieldType,
            isInPublicProfile: isInPublicProfile,
            sortOrder: items.filter({ $0.category == category }).count
        )
        items.append(newItem)
    }

    // MARK: - Update Data

    func updateItem(_ item: PersonalDataItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        }
    }

    // MARK: - Delete Data

    func deleteItem(_ itemId: String) {
        items.removeAll { $0.id == itemId }
    }

    // MARK: - Toggle Public Profile

    func togglePublicProfile(_ itemId: String) {
        if let index = items.firstIndex(where: { $0.id == itemId }) {
            items[index].isInPublicProfile.toggle()
            items[index].updatedAt = Date()
        }
    }

    // MARK: - Sort Operations

    func moveUp(_ itemId: String) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        let category = items[index].category
        let categoryItems = items.filter { $0.category == category }.sorted { $0.sortOrder < $1.sortOrder }
        guard let catIndex = categoryItems.firstIndex(where: { $0.id == itemId }), catIndex > 0 else { return }

        let prevId = categoryItems[catIndex - 1].id
        if let prevIndex = items.firstIndex(where: { $0.id == prevId }) {
            let temp = items[index].sortOrder
            items[index].sortOrder = items[prevIndex].sortOrder
            items[prevIndex].sortOrder = temp
        }
    }

    func moveDown(_ itemId: String) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        let category = items[index].category
        let categoryItems = items.filter { $0.category == category }.sorted { $0.sortOrder < $1.sortOrder }
        guard let catIndex = categoryItems.firstIndex(where: { $0.id == itemId }), catIndex < categoryItems.count - 1 else { return }

        let nextId = categoryItems[catIndex + 1].id
        if let nextIndex = items.firstIndex(where: { $0.id == nextId }) {
            let temp = items[index].sortOrder
            items[index].sortOrder = items[nextIndex].sortOrder
            items[nextIndex].sortOrder = temp
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
}
