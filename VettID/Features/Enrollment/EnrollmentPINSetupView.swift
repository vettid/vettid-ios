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
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    headerSection
                    pinFieldsSection
                    requirementsSection
                    infoSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            submitButton
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .navigationBarBackButtonHidden(viewModel.state == .processingPIN)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Set Your PIN")
                .font(.title2)
                .fontWeight(.bold)

            Text("Create a PIN (4–8 digits) to secure your vault. This PIN is encrypted and sent directly to the secure enclave.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - PIN Fields

    private var pinFieldsSection: some View {
        VStack(spacing: 12) {
            outlinedSecureField(
                title: "PIN",
                placeholder: "Enter 4–8 digit PIN",
                text: $viewModel.pin,
                focused: .pin
            )
            outlinedSecureField(
                title: "Confirm PIN",
                placeholder: "Confirm PIN",
                text: $viewModel.confirmPin,
                focused: .confirm
            )
        }
    }

    private func outlinedSecureField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        focused: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField(placeholder, text: text)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: focused)
                .padding(.vertical, 14)
                .padding(.horizontal, 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(focusedField == focused ? Color.accentColor : Color(.separator), lineWidth: 1)
                )
                .onChange(of: text.wrappedValue) { newValue in
                    var cleaned = newValue.filter { $0.isNumber }
                    if cleaned.count > 8 { cleaned = String(cleaned.prefix(8)) }
                    if cleaned != newValue { text.wrappedValue = cleaned }
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
                    text: "4–8 digits",
                    isMet: (4...8).contains(viewModel.pin.count) && viewModel.pin.allSatisfy { $0.isNumber }
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
        Button {
            focusedField = nil
            // Route through NATS (matches Android's NitroEnrollmentClient.setupPin).
            // The old `submitPIN()` call hit the deprecated HTTP enrollSetPIN
            // endpoint and returned 404 because the supervisor no longer
            // serves that route post-architecture-v2.
            Task { await viewModel.submitPINViaNats() }
        } label: {
            HStack(spacing: 8) {
                if viewModel.state == .processingPIN {
                    ProgressView().tint(.white)
                } else {
                    Text("Continue")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!viewModel.isPINValid || viewModel.state == .processingPIN)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        EnrollmentPINSetupView(viewModel: EnrollmentViewModel())
    }
}
