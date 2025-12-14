import SwiftUI

// MARK: - Personal Data View

struct PersonalDataView: View {
    @StateObject private var viewModel = PersonalDataViewModel()
    @State private var expandedSections: Set<PersonalData.DataCategory> = [.publicInfo, .privateInfo]
    @State private var showAddData = false
    @State private var selectedCategory: PersonalData.DataCategory = .publicInfo

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                loadingView

            case .loaded:
                dataContent

            case .error(let message):
                errorView(message)
            }
        }
        .task {
            await viewModel.loadData()
        }
        .sheet(isPresented: $showAddData) {
            AddPersonalDataView(
                viewModel: viewModel,
                initialCategory: selectedCategory
            )
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
            Text("Loading personal data...")
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Data Content

    private var dataContent: some View {
        List {
            // Public Section
            dataSection(
                category: .publicInfo,
                data: viewModel.publicData
            )

            // Private Section
            dataSection(
                category: .privateInfo,
                data: viewModel.privateData
            )

            // Keys Section
            dataSection(
                category: .keys,
                data: viewModel.keysData
            )

            // Minor Secrets Section
            dataSection(
                category: .minorSecrets,
                data: viewModel.minorSecretsData
            )
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Data Section

    private func dataSection(category: PersonalData.DataCategory, data: [PersonalData]) -> some View {
        Section {
            if expandedSections.contains(category) {
                if data.isEmpty {
                    emptyCategory(category)
                } else {
                    ForEach(data) { item in
                        PersonalDataRowView(data: item)
                    }
                    .onDelete { indexSet in
                        deleteItems(at: indexSet, in: category)
                    }
                }
            }
        } header: {
            sectionHeader(category: category, count: data.count)
        }
    }

    private func sectionHeader(category: PersonalData.DataCategory, count: Int) -> some View {
        Button(action: {
            withAnimation {
                if expandedSections.contains(category) {
                    expandedSections.remove(category)
                } else {
                    expandedSections.insert(category)
                }
            }
        }) {
            HStack {
                Image(systemName: category.icon)
                    .foregroundStyle(.blue)

                Text(category.displayName)
                    .foregroundStyle(.primary)

                Text("(\(count))")
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: {
                    selectedCategory = category
                    showAddData = true
                }) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }

                Image(systemName: expandedSections.contains(category) ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func emptyCategory(_ category: PersonalData.DataCategory) -> some View {
        VStack(spacing: 8) {
            Text("No \(category.displayName.lowercased()) data")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(category.description)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button("Add \(category.displayName)") {
                selectedCategory = category
                showAddData = true
            }
            .font(.caption)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                Task { await viewModel.loadData() }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
    }

    // MARK: - Actions

    private func deleteItems(at indexSet: IndexSet, in category: PersonalData.DataCategory) {
        let data = viewModel.dataForCategory(category)
        for index in indexSet {
            Task {
                await viewModel.deleteData(data[index])
            }
        }
    }
}

// MARK: - Personal Data Row View

struct PersonalDataRowView: View {
    let data: PersonalData

    var body: some View {
        NavigationLink(destination: PersonalDataDetailView(data: data)) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(data.fieldName)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(maskedValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Visibility badge
                HStack(spacing: 4) {
                    Image(systemName: data.visibility.icon)
                        .font(.caption2)
                    Text(data.visibility.displayName)
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.systemGray6))
                .cornerRadius(4)
            }
        }
    }

    private var maskedValue: String {
        if data.category == .keys || data.category == .minorSecrets {
            return "••••••••"
        }
        return data.value
    }
}

// MARK: - Personal Data Detail View

struct PersonalDataDetailView: View {
    let data: PersonalData

    @State private var isEditing = false
    @State private var editedValue: String = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        List {
            Section("Value") {
                if isEditing {
                    TextField("Value", text: $editedValue)
                } else {
                    Text(data.value)
                        .font(.body)
                }
            }

            Section("Visibility") {
                HStack {
                    Image(systemName: data.visibility.icon)
                    Text(data.visibility.displayName)
                }
            }

            Section("Information") {
                LabeledContent("Category", value: data.category.displayName)
                LabeledContent("Created", value: data.createdAt.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Updated", value: data.updatedAt.formatted(date: .abbreviated, time: .omitted))
            }

            Section {
                Button("Delete", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
        .navigationTitle(data.fieldName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "Save" : "Edit") {
                    if isEditing {
                        // Save changes
                    }
                    isEditing.toggle()
                }
            }
        }
        .onAppear {
            editedValue = data.value
        }
        .confirmationDialog("Delete this data?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                // Delete the data
            }
        }
    }
}

// MARK: - Add Personal Data View

struct AddPersonalDataView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: PersonalDataViewModel

    let initialCategory: PersonalData.DataCategory

    @State private var fieldName = ""
    @State private var value = ""
    @State private var category: PersonalData.DataCategory
    @State private var visibility: PersonalData.DataVisibility = .selfOnly

    init(viewModel: PersonalDataViewModel, initialCategory: PersonalData.DataCategory) {
        self.viewModel = viewModel
        self.initialCategory = initialCategory
        self._category = State(initialValue: initialCategory)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Field Details") {
                    TextField("Field Name", text: $fieldName)

                    TextField("Value", text: $value)

                    Picker("Category", selection: $category) {
                        ForEach(PersonalData.DataCategory.allCases, id: \.self) { cat in
                            Label(cat.displayName, systemImage: cat.icon)
                                .tag(cat)
                        }
                    }

                    Picker("Visibility", selection: $visibility) {
                        ForEach([PersonalData.DataVisibility.everyone, .connections, .selfOnly], id: \.self) { vis in
                            Label(vis.displayName, systemImage: vis.icon)
                                .tag(vis)
                        }
                    }
                }

                Section {
                    Text(category.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveData()
                    }
                    .disabled(fieldName.isEmpty || value.isEmpty)
                }
            }
        }
    }

    private func saveData() {
        Task {
            await viewModel.addData(
                fieldName: fieldName,
                value: value,
                category: category,
                visibility: visibility
            )
            dismiss()
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PersonalDataView()
    }
}
