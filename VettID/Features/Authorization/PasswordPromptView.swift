import SwiftUI

/// View for prompting user password to authorize sensitive operations
/// (Architecture v2.0 Section 5.10)
struct PasswordPromptView: View {
    let operation: AuthorizableOperation
    let onAuthorize: (String) async throws -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var isAuthorizing = false
    @State private var errorMessage: String?
    @State private var showPassword = false
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Warning icon and operation info
                VStack(spacing: 16) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)

                    Text("Authorization Required")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Enter your password to \(operation.displayName.lowercased())")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top)

                // Warning message
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(operation.warningMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)

                // Password field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Password")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack {
                        if showPassword {
                            TextField("Enter password", text: $password)
                                .textContentType(.password)
                                .focused($isPasswordFocused)
                        } else {
                            SecureField("Enter password", text: $password)
                                .textContentType(.password)
                                .focused($isPasswordFocused)
                        }

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                }

                // Error message
                if let error = errorMessage {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                // Action buttons
                VStack(spacing: 12) {
                    Button {
                        attemptAuthorization()
                    } label: {
                        HStack {
                            if isAuthorizing {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Authorize")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(password.isEmpty ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(password.isEmpty || isAuthorizing)

                    Button("Cancel") {
                        onCancel()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Authorize \(operation.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
            .onAppear {
                isPasswordFocused = true
            }
        }
    }

    private func attemptAuthorization() {
        guard !password.isEmpty else { return }

        isAuthorizing = true
        errorMessage = nil

        Task {
            do {
                try await onAuthorize(password)
            } catch let error as AuthorizationError {
                await MainActor.run {
                    errorMessage = error.errorDescription
                    isAuthorizing = false
                    if case .incorrectPassword = error {
                        password = ""
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isAuthorizing = false
                }
            }
        }
    }
}

// MARK: - Authorization Modifier

/// View modifier for adding authorization requirement to buttons/actions
struct AuthorizationRequiredModifier: ViewModifier {
    let operation: AuthorizableOperation
    let authorizationService: OperationAuthorizationService
    let action: (AuthorizationToken) async throws -> Void

    @State private var showPasswordPrompt = false
    @State private var isRequestingChallenge = false

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                beginAuthorization()
            }
            .disabled(isRequestingChallenge)
            .sheet(isPresented: $showPasswordPrompt) {
                PasswordPromptView(
                    operation: operation,
                    onAuthorize: { password in
                        try await authorizationService.authorize(password: password) { token in
                            try await action(token)
                        }
                        showPasswordPrompt = false
                    },
                    onCancel: {
                        authorizationService.cancel()
                        showPasswordPrompt = false
                    }
                )
                .interactiveDismissDisabled(authorizationService.state.isProcessing)
            }
    }

    private func beginAuthorization() {
        isRequestingChallenge = true

        Task {
            do {
                _ = try await authorizationService.requestChallenge(for: operation)
                await MainActor.run {
                    isRequestingChallenge = false
                    showPasswordPrompt = true
                }
            } catch {
                await MainActor.run {
                    isRequestingChallenge = false
                    // Could show error alert here
                }
            }
        }
    }
}

extension View {
    /// Require password authorization before performing an action
    func requiresAuthorization(
        for operation: AuthorizableOperation,
        using service: OperationAuthorizationService,
        action: @escaping (AuthorizationToken) async throws -> Void
    ) -> some View {
        modifier(AuthorizationRequiredModifier(
            operation: operation,
            authorizationService: service,
            action: action
        ))
    }
}

// MARK: - Convenience Alert

/// Alert-style password prompt for quick authorization
struct AuthorizationAlert: ViewModifier {
    @Binding var isPresented: Bool
    let operation: AuthorizableOperation
    let authorizationService: OperationAuthorizationService
    let onAuthorized: (AuthorizationToken) async throws -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                PasswordPromptView(
                    operation: operation,
                    onAuthorize: { password in
                        try await authorizationService.authorize(password: password) { token in
                            try await onAuthorized(token)
                        }
                        isPresented = false
                    },
                    onCancel: {
                        authorizationService.cancel()
                        isPresented = false
                    }
                )
                .presentationDetents([.medium])
                .interactiveDismissDisabled(authorizationService.state.isProcessing)
            }
    }
}

extension View {
    /// Show password authorization prompt as a sheet
    func authorizationAlert(
        isPresented: Binding<Bool>,
        operation: AuthorizableOperation,
        service: OperationAuthorizationService,
        onAuthorized: @escaping (AuthorizationToken) async throws -> Void
    ) -> some View {
        modifier(AuthorizationAlert(
            isPresented: isPresented,
            operation: operation,
            authorizationService: service,
            onAuthorized: onAuthorized
        ))
    }
}

// MARK: - Preview

#Preview {
    PasswordPromptView(
        operation: .deleteSecret,
        onAuthorize: { password in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            print("Authorized with password: \(password.prefix(1))***")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}
