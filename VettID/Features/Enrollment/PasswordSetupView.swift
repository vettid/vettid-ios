import SwiftUI

/// Password creation view with strength meter and requirements
struct PasswordSetupView: View {
    @ObservedObject var viewModel: EnrollmentViewModel
    @FocusState private var focusedField: Field?

    enum Field {
        case password, confirm
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    headerSection
                    passwordFieldsSection
                    strengthIndicator
                    requirementsSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            submitButton
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .navigationBarBackButtonHidden(viewModel.state == .processingPassword)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Protean Credential Password")
                .font(.title2)
                .fontWeight(.bold)

            Text("This password protects your Protean Credential and is required for sensitive operations.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Password Fields

    private var passwordFieldsSection: some View {
        VStack(spacing: 12) {
            outlinedSecureField(
                title: "Password",
                placeholder: "Enter password",
                text: $viewModel.password,
                focused: .password,
                onChange: { viewModel.updatePasswordStrength() }
            )
            outlinedSecureField(
                title: "Confirm Password",
                placeholder: "Confirm password",
                text: $viewModel.confirmPassword,
                focused: .confirm
            )
        }
    }

    private func outlinedSecureField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        focused: Field,
        onChange: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField(placeholder, text: text)
                .textContentType(.newPassword)
                .focused($focusedField, equals: focused)
                .padding(.vertical, 14)
                .padding(.horizontal, 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(focusedField == focused ? Color.accentColor : Color(.separator), lineWidth: 1)
                )
                .onChange(of: text.wrappedValue) { _ in onChange?() }
        }
    }

    // MARK: - Strength Indicator

    private var strengthIndicator: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Password Strength")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(viewModel.passwordStrength.label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(viewModel.passwordStrength.color)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))
                        .frame(height: 8)

                    // Filled portion
                    RoundedRectangle(cornerRadius: 4)
                        .fill(viewModel.passwordStrength.color)
                        .frame(
                            width: geometry.size.width * strengthProgress,
                            height: 8
                        )
                        .animation(.easeInOut(duration: 0.2), value: viewModel.passwordStrength)
                }
            }
            .frame(height: 8)
        }
        .padding(.vertical, 8)
    }

    private var strengthProgress: Double {
        guard !viewModel.password.isEmpty else { return 0 }
        return Double(viewModel.passwordStrength.rawValue + 1) / 5.0
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
                    text: "At least 12 characters",
                    isMet: viewModel.password.count >= 12
                )

                requirementRow(
                    text: "Good password strength",
                    isMet: viewModel.passwordStrength >= .good
                )

                requirementRow(
                    text: "Passwords match",
                    isMet: !viewModel.confirmPassword.isEmpty && viewModel.password == viewModel.confirmPassword
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

    // MARK: - Submit Button

    private var submitButton: some View {
        Button {
            focusedField = nil
            Task { await viewModel.submitPassword() }
        } label: {
            HStack(spacing: 8) {
                if viewModel.state == .processingPassword {
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
        .disabled(!viewModel.isPasswordValid || viewModel.state == .processingPassword)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PasswordSetupView(viewModel: EnrollmentViewModel())
    }
}
