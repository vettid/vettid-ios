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
    @Published var publicData: [PersonalData] = []
    @Published var privateData: [PersonalData] = []
    @Published var keysData: [PersonalData] = []
    @Published var minorSecretsData: [PersonalData] = []

    // MARK: - Load Data

    func loadData() async {
        state = .loading

        // Simulate loading delay
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Load mock data and categorize
        let allData = PersonalData.mockData()

        publicData = allData.filter { $0.category == .publicInfo }
        privateData = allData.filter { $0.category == .privateInfo }
        keysData = allData.filter { $0.category == .keys }
        minorSecretsData = allData.filter { $0.category == .minorSecrets }

        state = .loaded
    }

    // MARK: - Add Data

    func addData(fieldName: String, value: String, category: PersonalData.DataCategory, visibility: PersonalData.DataVisibility) async {
        let newData = PersonalData(
            id: UUID().uuidString,
            fieldName: fieldName,
            value: value,
            category: category,
            visibility: visibility,
            createdAt: Date(),
            updatedAt: Date()
        )

        switch category {
        case .publicInfo:
            publicData.insert(newData, at: 0)
        case .privateInfo:
            privateData.insert(newData, at: 0)
        case .keys:
            keysData.insert(newData, at: 0)
        case .minorSecrets:
            minorSecretsData.insert(newData, at: 0)
        }
    }

    // MARK: - Update Data

    func updateData(_ data: PersonalData, newValue: String) async {
        var updated = data
        updated.value = newValue

        switch data.category {
        case .publicInfo:
            if let index = publicData.firstIndex(where: { $0.id == data.id }) {
                publicData[index] = updated
            }
        case .privateInfo:
            if let index = privateData.firstIndex(where: { $0.id == data.id }) {
                privateData[index] = updated
            }
        case .keys:
            if let index = keysData.firstIndex(where: { $0.id == data.id }) {
                keysData[index] = updated
            }
        case .minorSecrets:
            if let index = minorSecretsData.firstIndex(where: { $0.id == data.id }) {
                minorSecretsData[index] = updated
            }
        }
    }

    // MARK: - Delete Data

    func deleteData(_ data: PersonalData) async {
        switch data.category {
        case .publicInfo:
            publicData.removeAll { $0.id == data.id }
        case .privateInfo:
            privateData.removeAll { $0.id == data.id }
        case .keys:
            keysData.removeAll { $0.id == data.id }
        case .minorSecrets:
            minorSecretsData.removeAll { $0.id == data.id }
        }
    }

    // MARK: - Category Helpers

    func dataForCategory(_ category: PersonalData.DataCategory) -> [PersonalData] {
        switch category {
        case .publicInfo: return publicData
        case .privateInfo: return privateData
        case .keys: return keysData
        case .minorSecrets: return minorSecretsData
        }
    }

    func isEmpty(for category: PersonalData.DataCategory) -> Bool {
        dataForCategory(category).isEmpty
    }

    var totalCount: Int {
        publicData.count + privateData.count + keysData.count + minorSecretsData.count
    }
}
