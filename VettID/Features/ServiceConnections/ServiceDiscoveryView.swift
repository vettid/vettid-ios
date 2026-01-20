import SwiftUI

/// View for discovering and connecting to services
struct ServiceDiscoveryView: View {
    @StateObject private var viewModel: ServiceDiscoveryViewModel
    @Environment(\.dismiss) private var dismiss

    init(serviceConnectionHandler: ServiceConnectionHandler) {
        self._viewModel = StateObject(wrappedValue: ServiceDiscoveryViewModel(
            serviceConnectionHandler: serviceConnectionHandler
        ))
    }

    var body: some View {
        NavigationView {
            Group {
                switch viewModel.state {
                case .idle:
                    idleView

                case .scanning:
                    scanningView

                case .discovering:
                    discoveringView

                case .discovered(let result):
                    discoveredView(result)

                case .reviewing:
                    reviewingView

                case .connecting:
                    connectingView

                case .connected(let connection):
                    connectedView(connection)

                case .error(let message):
                    errorView(message)
                }
            }
            .navigationTitle("Connect to Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.clearError() }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .sheet(isPresented: $viewModel.showingContractReview) {
            if let result = viewModel.discoveryResult {
                ContractReviewView(
                    discoveryResult: result,
                    selectedOptionalFields: $viewModel.selectedOptionalFields,
                    onAccept: {
                        Task { await viewModel.acceptContract() }
                    },
                    onDecline: {
                        viewModel.declineContract()
                    }
                )
            }
        }
    }

    // MARK: - Idle View

    private var idleView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "building.2.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            VStack(spacing: 8) {
                Text("Connect to a Service")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Scan a QR code or enter a service code to connect")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            VStack(spacing: 16) {
                Button(action: { viewModel.startScanning() }) {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                    Text("or")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                }
                .padding(.horizontal)

                VStack(spacing: 12) {
                    TextField("Enter service code", text: $viewModel.manualCode)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(action: {
                        Task { await viewModel.discoverFromManualCode() }
                    }) {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(viewModel.manualCode.isEmpty)
                }
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Scanning View

    private var scanningView: some View {
        VStack(spacing: 24) {
            // QR Scanner placeholder
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black)
                .frame(height: 300)
                .overlay(
                    VStack {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 60))
                            .foregroundColor(.white)
                        Text("Point camera at QR code")
                            .foregroundColor(.white)
                            .padding(.top, 8)
                    }
                )
                .padding(.horizontal, 24)

            Button("Cancel") {
                viewModel.cancelScanning()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Discovering View

    private var discoveringView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Discovering service...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Discovered View

    private func discoveredView(_ result: ServiceDiscoveryResult) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // Service Profile Card
                ServiceProfileCard(profile: result.serviceProfile, compact: false)
                    .padding(.horizontal)

                // Missing Fields Warning
                if viewModel.hasMissingRequiredFields {
                    MissingFieldsWarning(fieldNames: viewModel.missingFieldNames)
                        .padding(.horizontal)
                }

                // Contract Summary
                ContractSummaryCard(contract: result.proposedContract)
                    .padding(.horizontal)

                // Action Buttons
                VStack(spacing: 12) {
                    Button(action: { viewModel.showContractReview() }) {
                        Text("Review Contract")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.hasMissingRequiredFields)

                    Button(action: { viewModel.reset() }) {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .padding(.top, 24)
        }
    }

    // MARK: - Reviewing View

    private var reviewingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Preparing contract...")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Connecting View

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Connecting to service...")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Establishing secure connection")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Connected View

    private func connectedView(_ connection: ServiceConnectionRecord) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)

            VStack(spacing: 8) {
                Text("Connected!")
                    .font(.title)
                    .fontWeight(.bold)

                Text("You are now connected to \(connection.serviceProfile.serviceName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            VStack(spacing: 8) {
                Text("Connection Failed")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()

            VStack(spacing: 12) {
                Button(action: { viewModel.reset() }) {
                    Text("Try Again")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: { dismiss() }) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Missing Fields Warning

struct MissingFieldsWarning: View {
    let fieldNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Missing Required Fields")
                    .font(.headline)
            }

            Text("This service requires the following fields that are not in your profile:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(fieldNames, id: \.self) { name in
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                        Text(name)
                            .font(.subheadline)
                    }
                }
            }

            Button(action: {
                // Navigate to profile to add fields
            }) {
                Label("Add to Profile", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - Contract Summary Card

struct ContractSummaryCard: View {
    let contract: ServiceDataContract

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Contract Summary")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                // Required Fields
                if !contract.requiredFields.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Required Fields")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        ForEach(contract.requiredFields) { field in
                            HStack {
                                Image(systemName: field.fieldType.icon)
                                    .foregroundColor(.blue)
                                    .frame(width: 20)
                                Text(field.fieldType.displayLabel)
                                    .font(.subheadline)
                            }
                        }
                    }
                }

                // Optional Fields
                if !contract.optionalFields.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Optional Fields")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        ForEach(contract.optionalFields) { field in
                            HStack {
                                Image(systemName: field.fieldType.icon)
                                    .foregroundColor(.secondary)
                                    .frame(width: 20)
                                Text(field.fieldType.displayLabel)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Divider()

                // Permissions
                VStack(alignment: .leading, spacing: 4) {
                    Text("Service Permissions")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if contract.canStoreData {
                        ServicePermissionRow(icon: "externaldrive.fill", text: "Can store data")
                    }
                    if contract.canSendMessages {
                        ServicePermissionRow(icon: "message.fill", text: "Can send messages")
                    }
                    if contract.canRequestAuth {
                        ServicePermissionRow(icon: "person.badge.key.fill", text: "Can request authentication")
                    }
                    if contract.canRequestPayment {
                        ServicePermissionRow(icon: "creditcard.fill", text: "Can request payments")
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct ServicePermissionRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
        }
    }
}

#if DEBUG
struct ServiceDiscoveryView_Previews: PreviewProvider {
    static var previews: some View {
        // Preview would require mock handler
        Text("ServiceDiscoveryView Preview")
    }
}
#endif
