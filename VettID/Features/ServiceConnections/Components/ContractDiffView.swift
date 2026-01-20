import SwiftUI

/// View for displaying contract update differences
struct ContractDiffView: View {
    let currentContract: ServiceDataContract
    let newContract: ServiceDataContract
    let changes: ContractChanges
    let onAccept: ([SharedFieldMapping]) -> Void
    let onReject: () -> Void

    @State private var selectedNewFields: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Version Header
                    VersionHeader(
                        currentVersion: currentContract.version,
                        newVersion: newContract.version
                    )
                    .padding(.horizontal)

                    // Warning Banner
                    WarningBanner()
                        .padding(.horizontal)

                    // Added Fields
                    if !changes.addedFields.isEmpty {
                        ChangesSection(
                            title: "New Requirements",
                            subtitle: "The service now requests these additional fields",
                            changeType: .added,
                            fields: changes.addedFields,
                            selectedFields: $selectedNewFields
                        )
                        .padding(.horizontal)
                    }

                    // Removed Fields
                    if !changes.removedFields.isEmpty {
                        RemovedFieldsSection(fields: changes.removedFields)
                            .padding(.horizontal)
                    }

                    // Changed Fields
                    if !changes.changedFields.isEmpty {
                        ChangesSection(
                            title: "Changed Fields",
                            subtitle: "These fields have updated terms",
                            changeType: .changed,
                            fields: changes.changedFields,
                            selectedFields: .constant([])
                        )
                        .padding(.horizontal)
                    }

                    // Permission Changes
                    if !changes.permissionChanges.isEmpty {
                        PermissionChangesSection(changes: changes.permissionChanges)
                            .padding(.horizontal)
                    }

                    // Rate Limit Changes
                    if let rateLimitChanges = changes.rateLimitChanges {
                        RateLimitChangesSection(changes: rateLimitChanges)
                            .padding(.horizontal)
                    }

                    // Action Buttons
                    VStack(spacing: 12) {
                        Button(action: {
                            // Build field mappings for new required fields
                            var mappings: [SharedFieldMapping] = []
                            for field in changes.addedFields {
                                if selectedNewFields.contains(field.field) || !isOptionalNewField(field) {
                                    mappings.append(SharedFieldMapping(
                                        fieldSpec: field,
                                        localFieldKey: field.field,
                                        sharedAt: Date(),
                                        lastUpdatedAt: nil
                                    ))
                                }
                            }
                            onAccept(mappings)
                            dismiss()
                        }) {
                            Text("Accept Changes")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button(role: .destructive, action: {
                            onReject()
                            dismiss()
                        }) {
                            Text("Reject & Disconnect")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                .padding(.vertical)
            }
            .navigationTitle("Contract Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func isOptionalNewField(_ field: FieldSpec) -> Bool {
        // Check if this field is in the new contract's optional fields
        return newContract.optionalFields.contains { $0.field == field.field }
    }
}

// MARK: - Version Header

struct VersionHeader: View {
    let currentVersion: Int
    let newVersion: Int

    var body: some View {
        HStack(spacing: 16) {
            VStack {
                Text("Current")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("v\(currentVersion)")
                    .font(.title2)
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)

            Image(systemName: "arrow.right")
                .font(.title2)
                .foregroundColor(.secondary)

            VStack {
                Text("New")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("v\(newVersion)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(12)
        }
    }
}

// MARK: - Warning Banner

struct WarningBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)

            Text("Rejecting this update will disconnect you from this service. You will need to reconnect to use it again.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - Changes Section

enum ChangeType {
    case added
    case changed

    var color: Color {
        switch self {
        case .added: return .green
        case .changed: return .orange
        }
    }

    var icon: String {
        switch self {
        case .added: return "plus.circle.fill"
        case .changed: return "arrow.triangle.2.circlepath.circle.fill"
        }
    }
}

struct ChangesSection: View {
    let title: String
    let subtitle: String
    let changeType: ChangeType
    let fields: [FieldSpec]
    @Binding var selectedFields: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: changeType.icon)
                    .foregroundColor(changeType.color)
                Text(title)
                    .font(.headline)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(fields) { field in
                FieldChangeRow(
                    field: field,
                    changeType: changeType,
                    isSelected: selectedFields.contains(field.field),
                    onToggle: {
                        if selectedFields.contains(field.field) {
                            selectedFields.remove(field.field)
                        } else {
                            selectedFields.insert(field.field)
                        }
                    }
                )
            }
        }
        .padding()
        .background(changeType.color.opacity(0.1))
        .cornerRadius(12)
    }
}

struct FieldChangeRow: View {
    let field: FieldSpec
    let changeType: ChangeType
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            if changeType == .added {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .blue : .secondary)
                }
            }

            Image(systemName: field.fieldType.icon)
                .foregroundColor(changeType.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(field.fieldType.displayLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(field.purpose)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Removed Fields Section

struct RemovedFieldsSection: View {
    let fields: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.gray)
                Text("Fields No Longer Required")
                    .font(.headline)
            }

            Text("The service no longer needs these fields")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(fields, id: \.self) { fieldName in
                HStack {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.gray)
                        .frame(width: 24)

                    Text(fieldName)
                        .font(.subheadline)
                        .strikethrough()
                        .foregroundColor(.secondary)

                    Spacer()
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - Permission Changes Section

struct PermissionChangesSection: View {
    let changes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "shield.fill")
                    .foregroundColor(.purple)
                Text("Permission Changes")
                    .font(.headline)
            }

            ForEach(changes, id: \.self) { change in
                HStack {
                    Image(systemName: "arrow.right.circle")
                        .foregroundColor(.purple)
                        .frame(width: 24)

                    Text(change)
                        .font(.subheadline)

                    Spacer()
                }
            }
        }
        .padding()
        .background(Color.purple.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - Rate Limit Changes Section

struct RateLimitChangesSection: View {
    let changes: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "speedometer")
                    .foregroundColor(.blue)
                Text("Rate Limit Changes")
                    .font(.headline)
            }

            Text(changes)
                .font(.subheadline)
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }
}

#if DEBUG
struct ContractDiffView_Previews: PreviewProvider {
    static var previews: some View {
        Text("ContractDiffView Preview")
    }
}
#endif
