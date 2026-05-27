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
                    pinMatchIndicator
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            submitButton
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .navigationBarBackButtonHidden(viewModel.state == .processingPIN)
        // iOS number-pad keyboards have no return key, so we surface
        // the Android-style "Next/Done" actions via a keyboard toolbar
        // bar. Mirrors what `imeAction = ImeAction.Next/Done` gives
        // for free on Android.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                if focusedField == .pin {
                    Button("Next") { focusedField = .confirm }
                        .disabled(viewModel.pin.count < 4)
                } else if focusedField == .confirm {
                    Button("Done") {
                        focusedField = nil
                        if viewModel.isPINValid {
                            Task { await viewModel.submitPINViaNats() }
                        }
                    }
                    .disabled(!viewModel.isPINValid)
                }
            }
        }
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

    // MARK: - PIN Match Indicator

    /// Mirrors Android's PinSetupPhaseContent feedback row: shows a green
    /// "PINs match" indicator once both fields hold matching 4+ digit
    /// PINs, or a red "PINs don't match" hint once Confirm is at least as
    /// long as PIN but the values diverge.
    private var pinMatchIndicator: some View {
        let pin = viewModel.pin
        let confirm = viewModel.confirmPin
        let pinsMatch = pin.count >= 4 && confirm.count >= 4 && pin == confirm
        let pinsMismatch = confirm.count >= pin.count && !confirm.isEmpty && pin != confirm

        return Group {
            if pinsMatch {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                    Text("PINs match")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            } else if pinsMismatch {
                Text("PINs don't match")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
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
