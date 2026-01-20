import SwiftUI

/// Full contract review view for accepting/declining a service connection
struct ContractReviewView: View {
    let discoveryResult: ServiceDiscoveryResult
    @Binding var selectedOptionalFields: Set<String>
    let onAccept: () -> Void
    let onDecline: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Service Header
                    ServiceProfileCard(profile: discoveryResult.serviceProfile, compact: false)

                    // Required Fields Section
                    if !discoveryResult.proposedContract.requiredFields.isEmpty {
                        FieldsSection(
                            title: "Required Information",
                            subtitle: "This service requires these fields to connect",
                            fields: discoveryResult.proposedContract.requiredFields,
                            selectedFields: .constant(Set(discoveryResult.proposedContract.requiredFields.map { $0.field })),
                            isSelectable: false
                        )
                    }

                    // Optional Fields Section
                    if !discoveryResult.proposedContract.optionalFields.isEmpty {
                        FieldsSection(
                            title: "Optional Information",
                            subtitle: "You can choose to share these fields",
                            fields: discoveryResult.proposedContract.optionalFields,
                            selectedFields: $selectedOptionalFields,
                            isSelectable: true
                        )
                    }

                    // Permissions Section
                    PermissionsSection(contract: discoveryResult.proposedContract)

                    // Rate Limits Section
                    if let maxRequests = discoveryResult.proposedContract.maxRequestsPerHour {
                        RateLimitsSection(
                            maxRequestsPerHour: maxRequests,
                            maxStorageMB: discoveryResult.proposedContract.maxStorageMB
                        )
                    }

                    // Legal Links
                    LegalLinksSection(
                        termsUrl: discoveryResult.proposedContract.termsUrl,
                        privacyUrl: discoveryResult.proposedContract.privacyUrl
                    )

                    // Action Buttons
                    VStack(spacing: 12) {
                        Button(action: {
                            onAccept()
                            dismiss()
                        }) {
                            Text("Accept & Connect")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button(action: {
                            onDecline()
                            dismiss()
                        }) {
                            Text("Decline")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("Review Contract")
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
}

// MARK: - Fields Section

struct FieldsSection: View {
    let title: String
    let subtitle: String
    let fields: [FieldSpec]
    @Binding var selectedFields: Set<String>
    let isSelectable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(fields) { field in
                    FieldRow(
                        field: field,
                        isSelected: selectedFields.contains(field.field),
                        isSelectable: isSelectable,
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
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Field Row

struct FieldRow: View {
    let field: FieldSpec
    let isSelected: Bool
    let isSelectable: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator or checkmark
            if isSelectable {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .blue : .secondary)
                }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
            }

            // Field icon
            Image(systemName: field.fieldType.icon)
                .foregroundColor(.secondary)
                .frame(width: 24)

            // Field info
            VStack(alignment: .leading, spacing: 2) {
                Text(field.fieldType.displayLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(field.purpose)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // Sensitivity indicator
            SensitivityBadge(level: field.fieldType.sensitivityLevel)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Sensitivity Badge

struct SensitivityBadge: View {
    let level: SensitivityLevel

    var body: some View {
        Text(level.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    private var color: Color {
        switch level {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        case .critical: return .purple
        }
    }
}

// MARK: - Permissions Section

struct PermissionsSection: View {
    let contract: ServiceDataContract

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Service Permissions")
                .font(.headline)

            VStack(spacing: 8) {
                if contract.canStoreData {
                    PermissionItem(
                        icon: "externaldrive.fill",
                        title: "Store Data",
                        description: "Can store data in your vault",
                        categories: contract.storageCategories
                    )
                }

                if contract.canSendMessages {
                    PermissionItem(
                        icon: "message.fill",
                        title: "Send Messages",
                        description: "Can send messages to you"
                    )
                }

                if contract.canRequestAuth {
                    PermissionItem(
                        icon: "person.badge.key.fill",
                        title: "Request Authentication",
                        description: "Can request you to verify your identity"
                    )
                }

                if contract.canRequestPayment {
                    PermissionItem(
                        icon: "creditcard.fill",
                        title: "Request Payments",
                        description: "Can request payments from you"
                    )
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Permission Item

struct PermissionItem: View {
    let icon: String
    let title: String
    let description: String
    var categories: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !categories.isEmpty {
                    Text("Categories: \(categories.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Rate Limits Section

struct RateLimitsSection: View {
    let maxRequestsPerHour: Int
    let maxStorageMB: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rate Limits")
                .font(.headline)

            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "speedometer")
                        .foregroundColor(.blue)
                        .frame(width: 24)

                    Text("Up to \(maxRequestsPerHour) requests per hour")
                        .font(.subheadline)

                    Spacer()
                }

                if let storage = maxStorageMB {
                    HStack {
                        Image(systemName: "internaldrive")
                            .foregroundColor(.blue)
                            .frame(width: 24)

                        Text("Up to \(storage) MB storage")
                            .font(.subheadline)

                        Spacer()
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Legal Links Section

struct LegalLinksSection: View {
    let termsUrl: String?
    let privacyUrl: String?

    var body: some View {
        VStack(spacing: 12) {
            if let termsUrl = termsUrl, let url = URL(string: termsUrl) {
                Link(destination: url) {
                    HStack {
                        Image(systemName: "doc.text")
                        Text("Terms of Service")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.subheadline)
                }
            }

            if let privacyUrl = privacyUrl, let url = URL(string: privacyUrl) {
                Link(destination: url) {
                    HStack {
                        Image(systemName: "hand.raised")
                        Text("Privacy Policy")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.subheadline)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

#if DEBUG
struct ContractReviewView_Previews: PreviewProvider {
    static var previews: some View {
        Text("ContractReviewView Preview")
    }
}
#endif
