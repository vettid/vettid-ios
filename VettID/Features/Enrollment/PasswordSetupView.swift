import SwiftUI

/// Password creation view with strength meter and requirements
struct PasswordSetupView: View {
    @ObservedObject var viewModel: EnrollmentViewModel
    @FocusState private var focusedField: Field?

    enum Field {
        case password, confirm
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                headerSection

                // Password fields
                passwordFieldsSection

                // Strength indicator
                strengthIndicator

                // Requirements
                requirementsSection

                // Submit button
                submitButton

                Spacer(minLength: 40)
            }
            .padding()
        }
        .navigationBarBackButtonHidden(viewModel.state == .processingPassword)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Create Your Password")
                .font(.title2)
                .fontWeight(.bold)

            Text("Create a password for managing Vault Services")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }

    // MARK: - Password Fields

    private var passwordFieldsSection: some View {
        VStack(spacing: 16) {
            // Password field
            VStack(alignment: .leading, spacing: 8) {
                Text("Password")
                    .font(.subheadline)
                    .fontWeight(.medium)

                SecureField("Enter password", text: $viewModel.password)
                    .textContentType(.newPassword)
                    .focused($focusedField, equals: .password)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    .onChange(of: viewModel.password) { _ in
                        viewModel.updatePasswordStrength()
                    }
            }

            // Confirm password field
            VStack(alignment: .leading, spacing: 8) {
                Text("Confirm Password")
                    .font(.subheadline)
                    .fontWeight(.medium)

                SecureField("Confirm password", text: $viewModel.confirmPassword)
                    .textContentType(.newPassword)
                    .focused($focusedField, equals: .confirm)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
            }
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
        Button(action: {
            focusedField = nil
            Task {
                await viewModel.submitPassword()
            }
        }) {
            HStack {
                if viewModel.state == .processingPassword {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Create Password")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(viewModel.isPasswordValid ? Color.blue : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(!viewModel.isPasswordValid || viewModel.state == .processingPassword)
        .padding(.top)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PasswordSetupView(viewModel: EnrollmentViewModel())
    }
}
