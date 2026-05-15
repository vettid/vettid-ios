import SwiftUI

// MARK: - Add Secret View (Template-Based)

struct AddSecretView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: SecretsViewModel

    @State private var selectedTemplate: SecretTemplate?
    @State private var showTemplateFields = false

    // Simple secret fields
    @State private var name = ""
    /// Phase 2.3: user-set disambiguator. Optional. Renders under the
    /// name on the list row and groups items in the catalog dialog.
    @State private var alias = ""
    /// Phase 2.5: selected crypto network. Only shown when the secret's
    /// category is cryptocurrency. The ticker is prefixed onto the
    /// alias on save (e.g. "BTC · Trading") so peers see the chain at
    /// a glance.
    @State private var cryptoNetwork: CryptoNetwork? = nil
    /// Phase 2.4: visibility tier. Defaults to `.private` per Android's
    /// "default new secrets to hidden" change — users opt secrets into
    /// the profile / catalog rather than accidentally publishing them.
    @State private var visibility: SecretVisibility = .private
    @State private var value = ""
    @State private var category: SecretCategory = .password
    @State private var notes = ""
    @State private var showValue = false

    // Template field values
    @State private var templateFieldValues: [String: String] = [:]

    var body: some View {
        NavigationView {
            List {
                // Template picker
                Section("Choose a Template") {
                    ForEach(SecretTemplate.allTemplates) { template in
                        Button {
                            selectedTemplate = template
                            category = template.category
                            name = template.name
                            templateFieldValues = [:]
                            showTemplateFields = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: template.iconName)
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.name)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                    Text(template.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // Or create a custom secret
                Section("Or Create Custom") {
                    TextField("Name", text: $name)

                    // Phase 2.3: optional short label that
                    // disambiguates similar secrets (e.g. "Wife",
                    // "Trading"). Shown in the list row as "Name —
                    // Alias" and used by the catalog dialog grouping.
                    TextField("Alias (optional)", text: $alias)

                    Picker("Category", selection: $category) {
                        ForEach(SecretCategory.allCases, id: \.self) { cat in
                            Label(cat.displayName, systemImage: cat.icon)
                                .tag(cat)
                        }
                    }

                    // Phase 2.5: network picker for crypto secrets.
                    // Selected ticker prefixes the alias as
                    // "TICKER · <alias>" so the row reads e.g.
                    // "Wallet — BTC · Trading" in the list.
                    if category == .cryptocurrency {
                        Picker("Network", selection: $cryptoNetwork) {
                            Text("Choose…").tag(CryptoNetwork?.none)
                            ForEach(CryptoNetworks.all) { net in
                                Text("\(net.ticker) — \(net.displayName)")
                                    .tag(Optional(net))
                            }
                        }
                    }

                    HStack {
                        if showValue {
                            TextField("Secret value", text: $value)
                        } else {
                            SecureField("Secret value", text: $value)
                        }
                        Button(action: { showValue.toggle() }) {
                            Image(systemName: showValue ? "eye.slash.fill" : "eye.fill")
                                .foregroundStyle(.secondary)
                        }
                    }

                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                // Phase 2.4: visibility tier. Minor secrets get
                // PROFILE / CATALOG / PRIVATE — USE_ONLY is reserved
                // for critical secrets (the value never leaves the
                // vault, so a `secret.get` reveal can't honor it).
                Section("Visibility") {
                    VisibilitySegmented(
                        selection: $visibility,
                        allowedTiers: [.profile, .catalog, .private]
                    )
                    Text(visibility.explainer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Secret")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveCustomSecret()
                    }
                    .disabled(name.isEmpty || value.isEmpty)
                }
            }
            .sheet(isPresented: $showTemplateFields) {
                if let template = selectedTemplate {
                    TemplateFieldsView(
                        template: template,
                        fieldValues: $templateFieldValues,
                        onSave: { values in
                            saveTemplateSecret(template: template, values: values)
                        }
                    )
                }
            }
        }
    }

    private func saveCustomSecret() {
        Task {
            // Phase 2.5: prefix the alias with the selected ticker for
            // crypto secrets (e.g. "BTC · Trading"). If no ticker is
            // chosen or the category isn't crypto, the alias goes
            // through unchanged. Matches Android's "TICKER · <alias>".
            let composed: String? = {
                let base = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard category == .cryptocurrency, let net = cryptoNetwork else {
                    return base.isEmpty ? nil : base
                }
                if base.isEmpty { return net.ticker }
                return "\(net.ticker) · \(base)"
            }()
            await viewModel.addSecret(
                name: name,
                value: value,
                category: category,
                notes: notes.isEmpty ? nil : notes,
                alias: composed,
                visibility: visibility
            )
            dismiss()
        }
    }

    private func saveTemplateSecret(template: SecretTemplate, values: [String: String]) {
        // Store as a structured secret with fields
        let secret = template.createSecret(fieldValues: values)
        // For now, add via the view model's simple interface
        Task {
            await viewModel.addSecret(
                name: secret.name,
                value: values.values.first ?? "",
                category: secret.category,
                notes: nil
            )
            dismiss()
        }
    }
}

// MARK: - Template Fields View

struct TemplateFieldsView: View {
    let template: SecretTemplate
    @Binding var fieldValues: [String: String]
    let onSave: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: template.iconName)
                            .font(.title2)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(template.name)
                                .font(.headline)
                            Text(template.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Fields") {
                    ForEach(template.fields, id: \.name) { field in
                        templateFieldInput(field: field)
                    }
                }
            }
            .navigationTitle(template.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(fieldValues)
                        dismiss()
                    }
                    .disabled(!hasRequiredFields)
                }
            }
        }
    }

    private var hasRequiredFields: Bool {
        // At least one field should be filled
        fieldValues.values.contains { !$0.isEmpty }
    }

    @ViewBuilder
    private func templateFieldInput(field: TemplateField) -> some View {
        let binding = Binding<String>(
            get: { fieldValues[field.name] ?? "" },
            set: { fieldValues[field.name] = $0 }
        )

        switch field.inputHint {
        case .password, .pin:
            SecureField(field.name, text: binding)
        case .number:
            TextField(field.name, text: binding)
                .keyboardType(.numberPad)
        case .date:
            // Phase 2.6: wire the existing DatePickerInput so DATE
            // fields on template forms (Credit Card, Passport, …) get
            // a tappable wheel picker instead of a typing-only field.
            // Calendar button on the input pops the picker sheet.
            DatePickerInput(
                label: field.name,
                dateString: binding,
                placeholder: field.placeholder.isEmpty ? "MM/DD/YYYY" : field.placeholder
            )
        case .expiryDate:
            // Same component for EXPIRY_DATE fields, just MM/YYYY-style.
            DatePickerInput(
                label: field.name,
                dateString: binding,
                placeholder: "MM/YYYY"
            )
        default:
            TextField(field.placeholder.isEmpty ? field.name : field.placeholder, text: binding)
        }
    }
}
