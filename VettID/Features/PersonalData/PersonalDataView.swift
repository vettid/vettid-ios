import SwiftUI

// MARK: - Personal Data View

struct PersonalDataView: View {
    @StateObject private var viewModel = PersonalDataViewModel()
    @State private var expandedSections: Set<DataCategory> = Set(DataCategory.allCases)
    @State private var showAddData = false
    @State private var selectedCategory: DataCategory = .identity

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
            ForEach(DataCategory.allCases, id: \.self) { category in
                dataSection(
                    category: category,
                    data: viewModel.items(for: category)
                )
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Data Section

    private func dataSection(category: DataCategory, data: [PersonalDataItem]) -> some View {
        Section {
            if expandedSections.contains(category) {
                if data.isEmpty {
                    emptyCategory(category)
                } else {
                    ForEach(data) { item in
                        PersonalDataRowView(item: item)
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

    private func sectionHeader(category: DataCategory, count: Int) -> some View {
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

    private func emptyCategory(_ category: DataCategory) -> some View {
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

    private func deleteItems(at indexSet: IndexSet, in category: DataCategory) {
        let data = viewModel.items(for: category)
        for index in indexSet {
            viewModel.deleteItem(data[index].id)
        }
    }
}

// MARK: - Personal Data Row View

struct PersonalDataRowView: View {
    let item: PersonalDataItem

    var body: some View {
        NavigationLink(destination: PersonalDataDetailView(item: item)) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(maskedValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if item.isInPublicProfile {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.caption2)
                        Text("Public")
                            .font(.caption2)
                    }
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(4)
                }

                if item.isSystemField {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var maskedValue: String {
        if item.isSensitive {
            return String(repeating: "\u{2022}", count: 8)
        }
        return item.value
    }
}

// MARK: - Personal Data Detail View

struct PersonalDataDetailView: View {
    let item: PersonalDataItem

    @State private var isEditing = false
    @State private var editedValue: String = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        List {
            Section("Value") {
                if isEditing {
                    TextField("Value", text: $editedValue)
                } else {
                    Text(item.value)
                        .font(.body)
                }
            }

            Section("Details") {
                LabeledContent("Category", value: item.category.displayName)
                LabeledContent("Type", value: item.type.displayName)
                LabeledContent("Field Type", value: item.fieldType.displayName)
                if item.isInPublicProfile {
                    Label("In Public Profile", systemImage: "globe")
                        .foregroundStyle(.blue)
                }
                if item.isSystemField {
                    Label("System Field", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Information") {
                LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Updated", value: item.updatedAt.formatted(date: .abbreviated, time: .omitted))
            }

            if !item.isSystemField {
                Section {
                    Button("Delete", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !item.isSystemField {
                ToolbarItem(placement: .primaryAction) {
                    Button(isEditing ? "Save" : "Edit") {
                        if isEditing {
                            // Save changes
                        }
                        isEditing.toggle()
                    }
                }
            }
        }
        .onAppear {
            editedValue = item.value
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

    let initialCategory: DataCategory

    @State private var name = ""
    @State private var value = ""
    @State private var category: DataCategory
    @State private var fieldType: FieldType = .text
    @State private var isInPublicProfile = false

    init(viewModel: PersonalDataViewModel, initialCategory: DataCategory) {
        self.viewModel = viewModel
        self.initialCategory = initialCategory
        self._category = State(initialValue: initialCategory)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Field Details") {
                    TextField("Field Name", text: $name)

                    TextField("Value", text: $value)

                    Picker("Category", selection: $category) {
                        ForEach(DataCategory.allCases, id: \.self) { cat in
                            Label(cat.displayName, systemImage: cat.icon)
                                .tag(cat)
                        }
                    }

                    Picker("Field Type", selection: $fieldType) {
                        ForEach(FieldType.allCases, id: \.self) { ft in
                            Text(ft.displayName)
                                .tag(ft)
                        }
                    }

                    Toggle("Include in Public Profile", isOn: $isInPublicProfile)
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
                    .disabled(name.isEmpty || value.isEmpty)
                }
            }
        }
    }

    private func saveData() {
        viewModel.addItem(
            name: name,
            value: value,
            category: category,
            fieldType: fieldType,
            isInPublicProfile: isInPublicProfile
        )
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PersonalDataView()
    }
}
