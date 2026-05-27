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
                    passwordMatchIndicator
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
                submitLabel: .next,
                onSubmit: { focusedField = .confirm },
                onChange: { viewModel.updatePasswordStrength() }
            )
            outlinedSecureField(
                title: "Confirm Password",
                placeholder: "Confirm password",
                text: $viewModel.confirmPassword,
                focused: .confirm,
                submitLabel: .done,
                onSubmit: {
                    focusedField = nil
                    if viewModel.isPasswordValid {
                        Task { await viewModel.submitPasswordViaNats() }
                    }
                }
            )
        }
    }

    private func outlinedSecureField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        focused: Field,
        submitLabel: SubmitLabel,
        onSubmit: @escaping () -> Void,
        onChange: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField(placeholder, text: text)
                .textContentType(.newPassword)
                .focused($focusedField, equals: focused)
                .submitLabel(submitLabel)
                .onSubmit(onSubmit)
                .padding(.vertical, 14)
                .padding(.horizontal, 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(focusedField == focused ? Color.accentColor : Color(.separator), lineWidth: 1)
                )
                .onChange(of: text.wrappedValue) { _ in onChange?() }
        }
    }

    // MARK: - Match Indicator

    /// Mirrors the PIN screen: green "Passwords match" once both fields
    /// hold matching 12+ char strings, red "Passwords don't match" when
    /// Confirm is at least as long as Password but the values diverge.
    private var passwordMatchIndicator: some View {
        let pw = viewModel.password
        let confirm = viewModel.confirmPassword
        let match = pw.count >= 12 && confirm.count >= 12 && pw == confirm
        let mismatch = !confirm.isEmpty && confirm.count >= pw.count && pw != confirm

        return Group {
            if match {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                    Text("Passwords match")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if mismatch {
                Text("Passwords don't match")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        Button {
            focusedField = nil
            // Route through NATS (matches Android's NitroEnrollmentClient
            // .createCredential). The plain `submitPassword()` is the
            // deprecated HTTP path that required `enrollmentToken` /
            // `passwordKeyId` / `enclavePublicKey` — none of which are
            // populated during the NATS attestation/PIN flow, so it
            // immediately threw `EnrollmentError.invalidState` ("Invalid
            // enrollment state").
            Task { await viewModel.submitPasswordViaNats() }
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

// MARK: - Verify Credential View

/// Mirrors Android `WizardState.VerifyingPassword` — user re-enters
/// the password they just created so the wizard can confirm the
/// credential round-trip works before moving on to permissions.
/// iOS does a local compare against the still-in-memory password
/// (kept by `EnrollmentViewModel.submitPasswordViaNats` until this
/// step runs); Android's `postEnrollmentAuthClient.authenticate`
/// vault round-trip isn't needed because iOS already holds both NATS
/// credentials (from `nats-bootstrap`) and the stored credential.
struct VerifyCredentialView: View {
    @ObservedObject var viewModel: EnrollmentViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer().frame(height: 16)

                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)

                    VStack(spacing: 8) {
                        Text("Verify Your Credential")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Enter your password to verify the credential was created successfully.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Password")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("Enter password", text: $viewModel.verifyPassword)
                            .textContentType(.password)
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit {
                                focused = false
                                if viewModel.isVerifyPasswordValid {
                                    Task { await viewModel.submitVerifyCredential() }
                                }
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(focused ? Color.accentColor : Color(.separator), lineWidth: 1)
                            )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            Button {
                focused = false
                Task { await viewModel.submitVerifyCredential() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.state == .processingVerify {
                        ProgressView().tint(.white)
                    } else {
                        Text("Verify")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .disabled(!viewModel.isVerifyPasswordValid || viewModel.state == .processingVerify)
        }
        .onAppear { focused = true }
    }
}

// MARK: - Verify Success View

/// Brief checkmark dwell between `submitVerifyCredential` and the
/// permissions ask — matches Android's `VerificationSuccess` state.
struct VerifySuccessView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color.accentColor)
            Text("Credential Verified")
                .font(.title2)
                .fontWeight(.bold)
            Text("Your credential has been verified successfully.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - Request Permissions View

/// Mirrors Android `WizardState.RequestingPermissions` — final
/// pre-completion step asking for notification permission. The ask
/// is optional; "Skip" moves straight to completion.
struct RequestPermissionsView: View {
    @ObservedObject var viewModel: EnrollmentViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer().frame(height: 24)

                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)

                    VStack(spacing: 8) {
                        Text("Stay Updated")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Allow VettID to send notifications for incoming connections, votes, and credential events.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        permissionRow(
                            icon: "person.2.fill",
                            title: "Connection requests",
                            description: "Know when someone wants to connect"
                        )
                        permissionRow(
                            icon: "checkmark.circle",
                            title: "Proposals & votes",
                            description: "Alerts when there's something to vote on"
                        )
                        permissionRow(
                            icon: "shield.lefthalf.filled",
                            title: "Credential activity",
                            description: "Heads-up on credential-related events"
                        )
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            VStack(spacing: 8) {
                Button {
                    Task { await viewModel.requestNotificationPermissionAndContinue() }
                } label: {
                    Text("Allow Notifications")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    viewModel.skipPermissions()
                } label: {
                    Text("Maybe Later")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private func permissionRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
