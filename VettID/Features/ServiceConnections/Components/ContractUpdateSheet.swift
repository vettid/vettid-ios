import SwiftUI
import LocalAuthentication

/// Sheet for reviewing and accepting contract updates
struct ContractUpdateSheet: View {
    let update: ContractUpdateDetails
    @Binding var isPresented: Bool
    let onDecision: (ContractUpdateDecision) async -> Void

    @State private var isProcessing = false
    @State private var error: String?
    @State private var selectedOptionalFields: Set<String> = []

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    updateHeader

                    // Version info
                    versionBadge

                    // Changes summary
                    changesSummary

                    // New required fields
                    if !update.changes.addedFields.filter({ isRequired($0) }).isEmpty {
                        newRequiredFieldsSection
                    }

                    // New optional fields
                    if !update.changes.addedFields.filter({ !isRequired($0) }).isEmpty {
                        newOptionalFieldsSection
                    }

                    // Removed fields
                    if !update.changes.removedFields.isEmpty {
                        removedFieldsSection
                    }

                    // Permission changes
                    if !update.changes.permissionChanges.isEmpty {
                        permissionChangesSection
                    }

                    // Reason for update
                    reasonSection

                    // Required by deadline
                    if let requiredBy = update.requiredBy {
                        deadlineSection(requiredBy)
                    }

                    // Terms links
                    termsLinks
                }
                .padding()
            }
            .navigationTitle("Contract Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") {
                        isPresented = false
                    }
                    .disabled(isProcessing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                actionButtons
                    .padding()
                    .background(Color(UIColor.systemBackground))
            }
        }
        .onAppear {
            // Pre-select all new optional fields
            let newOptional = update.changes.addedFields.filter { !isRequired($0) }
            selectedOptionalFields = Set(newOptional.map { $0.field })
        }
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            if let error = error {
                Text(error)
            }
        }
    }

    // MARK: - Header

    private var updateHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.arrow.up.fill")
                .font(.system(size: 48))
                .foregroundColor(.purple)

            Text(update.serviceName)
                .font(.title2)
                .fontWeight(.bold)

            Text("has updated their data contract")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Version Badge

    private var versionBadge: some View {
        HStack(spacing: 8) {
            Text("v\(update.previousVersion)")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(16)

            Image(systemName: "arrow.right")
                .foregroundColor(.secondary)

            Text("v\(update.newVersion)")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.purple.opacity(0.15))
                .foregroundColor(.purple)
                .cornerRadius(16)
        }
        .font(.subheadline)
        .fontWeight(.medium)
    }

    // MARK: - Changes Summary

    private var changesSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's Changed")
                .font(.headline)

            HStack(spacing: 16) {
                if !update.changes.addedFields.isEmpty {
                    changeStat(
                        count: update.changes.addedFields.count,
                        label: "Added",
                        color: .green,
                        icon: "plus.circle.fill"
                    )
                }

                if !update.changes.removedFields.isEmpty {
                    changeStat(
                        count: update.changes.removedFields.count,
                        label: "Removed",
                        color: .red,
                        icon: "minus.circle.fill"
                    )
                }

                if !update.changes.changedFields.isEmpty {
                    changeStat(
                        count: update.changes.changedFields.count,
                        label: "Modified",
                        color: .orange,
                        icon: "arrow.triangle.2.circlepath"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changeStat(count: Int, label: String, color: Color, icon: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text("\(count)")
                    .fontWeight(.bold)
            }
            .font(.subheadline)
            .foregroundColor(color)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(minWidth: 80)
        .background(color.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - New Required Fields

    private var newRequiredFieldsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("New Required Fields", systemImage: "exclamationmark.circle.fill")
                .font(.headline)
                .foregroundColor(.orange)

            ForEach(update.changes.addedFields.filter { isRequired($0) }) { field in
                fieldRow(field, color: .orange, isSelectable: false, isSelected: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - New Optional Fields

    private var newOptionalFieldsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("New Optional Fields", systemImage: "checkmark.circle")
                .font(.headline)
                .foregroundColor(.blue)

            ForEach(update.changes.addedFields.filter { !isRequired($0) }) { field in
                fieldRow(
                    field,
                    color: .blue,
                    isSelectable: true,
                    isSelected: selectedOptionalFields.contains(field.field)
                ) {
                    toggleOptionalField(field.field)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Removed Fields

    private var removedFieldsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Removed Fields", systemImage: "minus.circle.fill")
                .font(.headline)
                .foregroundColor(.green)

            Text("The service no longer requires these fields:")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(update.changes.removedFields, id: \.self) { fieldId in
                HStack {
                    Image(systemName: "minus.circle")
                        .foregroundColor(.green)
                    Text(ServiceFieldType(rawValue: fieldId)?.displayLabel ?? fieldId)
                        .strikethrough()
                        .foregroundColor(.secondary)
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Permission Changes

    private var permissionChangesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Permission Changes", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundColor(.purple)

            ForEach(update.changes.permissionChanges, id: \.self) { change in
                HStack(alignment: .top) {
                    Image(systemName: "arrow.right.circle")
                        .foregroundColor(.purple)
                    Text(change)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Reason Section

    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why This Update?")
                .font(.headline)

            Text(update.reason)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Deadline Section

    private func deadlineSection(_ deadline: Date) -> some View {
        HStack {
            Image(systemName: "calendar.badge.clock")
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Update Required By")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(deadline.formatted(date: .long, time: .omitted))
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Spacer()

            if deadline < Date().addingTimeInterval(86400 * 7) {
                Text("Soon")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Terms Links

    private var termsLinks: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let termsUrl = update.termsUrl, let url = URL(string: termsUrl) {
                Link(destination: url) {
                    Label("View Terms of Service", systemImage: "doc.text")
                }
            }

            if let privacyUrl = update.privacyUrl, let url = URL(string: privacyUrl) {
                Link(destination: url) {
                    Label("View Privacy Policy", systemImage: "hand.raised")
                }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Error message
            if let error = error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack(spacing: 16) {
                // Decline button
                Button(action: {
                    Task {
                        await handleDecision(accepted: false)
                    }
                }) {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isProcessing)

                // Accept button
                Button(action: {
                    Task {
                        await handleAccept()
                    }
                }) {
                    HStack {
                        if isProcessing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        }
                        Text("Accept Update")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isProcessing)
            }

            Text("You can decline but service access may be limited")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helper Views

    private func fieldRow(
        _ field: FieldSpec,
        color: Color,
        isSelectable: Bool,
        isSelected: Bool,
        onToggle: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: field.fieldType.icon)
                .foregroundColor(color)
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

            if isSelectable, let onToggle = onToggle {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? color : .secondary)
                }
                .buttonStyle(.plain)
            } else if !isSelectable {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(color.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Actions

    private func isRequired(_ field: FieldSpec) -> Bool {
        // Check if field is in the required list of the new contract
        update.newRequiredFieldIds.contains(field.field)
    }

    private func toggleOptionalField(_ fieldId: String) {
        if selectedOptionalFields.contains(fieldId) {
            selectedOptionalFields.remove(fieldId)
        } else {
            selectedOptionalFields.insert(fieldId)
        }
    }

    private func handleAccept() async {
        isProcessing = true
        error = nil

        // Require biometric authentication
        let context = LAContext()
        var authError: NSError?

        let canUseBiometrics = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &authError
        )

        let policy: LAPolicy = canUseBiometrics ?
            .deviceOwnerAuthenticationWithBiometrics :
            .deviceOwnerAuthentication

        do {
            let success = try await context.evaluatePolicy(
                policy,
                localizedReason: "Authenticate to accept the contract update"
            )

            if success {
                await handleDecision(accepted: true)
            } else {
                error = "Authentication failed"
                isProcessing = false
            }
        } catch {
            self.error = error.localizedDescription
            isProcessing = false
        }
    }

    private func handleDecision(accepted: Bool) async {
        isProcessing = true

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(accepted ? .success : .warning)

        let decision = ContractUpdateDecision(
            connectionId: update.connectionId,
            accepted: accepted,
            acceptedOptionalFields: accepted ? Array(selectedOptionalFields) : [],
            decidedAt: Date()
        )

        await onDecision(decision)
        isPresented = false
    }
}

// MARK: - Contract Update Types

/// Details of a contract update
struct ContractUpdateDetails: Codable {
    let connectionId: String
    let serviceName: String
    let serviceLogoUrl: String?
    let previousVersion: Int
    let newVersion: Int
    let changes: ContractChanges
    let reason: String
    let publishedAt: Date
    let requiredBy: Date?
    let termsUrl: String?
    let privacyUrl: String?
    let newRequiredFieldIds: [String]

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case serviceName = "service_name"
        case serviceLogoUrl = "service_logo_url"
        case previousVersion = "previous_version"
        case newVersion = "new_version"
        case changes
        case reason
        case publishedAt = "published_at"
        case requiredBy = "required_by"
        case termsUrl = "terms_url"
        case privacyUrl = "privacy_url"
        case newRequiredFieldIds = "new_required_field_ids"
    }
}

/// Decision on a contract update
struct ContractUpdateDecision: Codable {
    let connectionId: String
    let accepted: Bool
    let acceptedOptionalFields: [String]
    let decidedAt: Date

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case accepted
        case acceptedOptionalFields = "accepted_optional_fields"
        case decidedAt = "decided_at"
    }
}

// MARK: - Preview

#if DEBUG
struct ContractUpdateSheet_Previews: PreviewProvider {
    static var previews: some View {
        ContractUpdateSheet(
            update: ContractUpdateDetails(
                connectionId: "conn-123",
                serviceName: "Example Store",
                serviceLogoUrl: nil,
                previousVersion: 1,
                newVersion: 2,
                changes: ContractChanges(
                    addedFields: [
                        FieldSpec(field: "phone", purpose: "Delivery updates", retention: "7 days"),
                        FieldSpec(field: "address", purpose: "Shipping", retention: "30 days")
                    ],
                    removedFields: [],
                    changedFields: [],
                    permissionChanges: ["Can now send promotional messages"],
                    rateLimitChanges: nil
                ),
                reason: "We're adding delivery notification features to improve your shopping experience.",
                publishedAt: Date(),
                requiredBy: Date().addingTimeInterval(86400 * 14),
                termsUrl: "https://example.com/terms",
                privacyUrl: "https://example.com/privacy",
                newRequiredFieldIds: []
            ),
            isPresented: .constant(true),
            onDecision: { _ in }
        )
    }
}
#endif
