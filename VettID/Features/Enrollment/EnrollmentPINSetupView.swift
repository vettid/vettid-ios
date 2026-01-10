import SwiftUI

/// PIN creation view for vault DEK binding during enrollment (Architecture v2.0 Section 5.7)
///
/// The PIN is used to unlock the vault on app open by deriving the DEK
/// through the enclave supervisor. This is separate from the password,
/// which authorizes individual operations.
struct EnrollmentPINSetupView: View {
    @ObservedObject var viewModel: EnrollmentViewModel
    @FocusState private var focusedField: Field?

    enum Field {
        case pin, confirm
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                headerSection

                // PIN fields
                pinFieldsSection

                // Requirements
                requirementsSection

                // Info section
                infoSection

                // Submit button
                submitButton

                Spacer(minLength: 40)
            }
            .padding()
        }
        .navigationBarBackButtonHidden(viewModel.state == .processingPIN)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.and.pencil.and.ellipsis")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Create Vault PIN")
                .font(.title2)
                .fontWeight(.bold)

            Text("Create a 6-digit PIN to unlock your vault. You'll enter this PIN each time you open the app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }

    // MARK: - PIN Fields

    private var pinFieldsSection: some View {
        VStack(spacing: 16) {
            // PIN field
            VStack(alignment: .leading, spacing: 8) {
                Text("PIN")
                    .font(.subheadline)
                    .fontWeight(.medium)

                SecureField("Enter 6-digit PIN", text: $viewModel.pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focusedField, equals: .pin)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    .onChange(of: viewModel.pin) { newValue in
                        // Limit to 6 digits
                        if newValue.count > 6 {
                            viewModel.pin = String(newValue.prefix(6))
                        }
                        // Only allow numbers
                        viewModel.pin = newValue.filter { $0.isNumber }
                    }
            }

            // Confirm PIN field
            VStack(alignment: .leading, spacing: 8) {
                Text("Confirm PIN")
                    .font(.subheadline)
                    .fontWeight(.medium)

                SecureField("Confirm PIN", text: $viewModel.confirmPin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focusedField, equals: .confirm)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    .onChange(of: viewModel.confirmPin) { newValue in
                        // Limit to 6 digits
                        if newValue.count > 6 {
                            viewModel.confirmPin = String(newValue.prefix(6))
                        }
                        // Only allow numbers
                        viewModel.confirmPin = newValue.filter { $0.isNumber }
                    }
            }
        }
    }

    // MARK: - Requirements

    private var requirementsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Requirements")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                requirementRow(
                    text: "Exactly 6 digits",
                    isMet: viewModel.pin.count == 6 && viewModel.pin.allSatisfy { $0.isNumber }
                )

                requirementRow(
                    text: "No weak patterns (123456, 111111)",
                    isMet: !viewModel.pin.isEmpty && viewModel.pinValidationErrors.filter { $0.contains("weak") }.isEmpty
                )

                requirementRow(
                    text: "PINs match",
                    isMet: !viewModel.confirmPin.isEmpty && viewModel.pin == viewModel.confirmPin
                )
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func requirementRow(text: String, isMet: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isMet ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isMet ? .green : .secondary)
                .font(.body)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(isMet ? .primary : .secondary)

            Spacer()
        }
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Your PIN and password serve different purposes:")
                    .font(.subheadline)
                    .fontWeight(.medium)
            } icon: {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("PIN - Unlocks your vault when you open the app")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Password - Authorizes sensitive vault operations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 28)
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Submit Button

    private var submitButton: some View {
        Button(action: {
            focusedField = nil
            Task {
                await viewModel.submitPIN()
            }
        }) {
            HStack {
                if viewModel.state == .processingPIN {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Set PIN")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(viewModel.isPINValid ? Color.blue : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(!viewModel.isPINValid || viewModel.state == .processingPIN)
        .padding(.top)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        EnrollmentPINSetupView(viewModel: EnrollmentViewModel())
    }
}
