import SwiftUI

// MARK: - Secrets View

struct SecretsView: View {
    let searchText: String

    @StateObject private var viewModel = SecretsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.state {
            case .loading:
                loadingView

            case .empty:
                emptyView

            case .loaded:
                secretsList

            case .error(let message):
                errorView(message)
            }
        }
        .task {
            await viewModel.loadSecrets()
        }
        .sheet(isPresented: $viewModel.showPasswordPrompt) {
            PasswordPromptSheet(viewModel: viewModel)
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
            Text("Loading secrets...")
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No Secrets")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add passwords, API keys, PINs, and other secrets to keep them secure.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Secrets List

    private var secretsList: some View {
        let filtered = viewModel.filteredSecrets(searchText: searchText)

        return Group {
            if filtered.isEmpty && !searchText.isEmpty {
                VStack(spacing: 20) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No secrets match \"\(searchText)\"")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(filtered) { secret in
                        SecretRowView(
                            secret: secret,
                            isRevealed: viewModel.revealedSecretId == secret.id,
                            revealedValue: viewModel.revealedSecretId == secret.id ? viewModel.revealedValue : nil,
                            autoHideCountdown: viewModel.autoHideCountdown,
                            onRevealTap: {
                                viewModel.requestRevealSecret(secret.id)
                            },
                            onHideTap: {
                                viewModel.hideSecret()
                            },
                            onCopyTap: {
                                if let value = viewModel.revealedValue {
                                    UIPasteboard.general.string = value
                                }
                            }
                        )
                    }
                    .onDelete { indexSet in
                        let filtered = viewModel.filteredSecrets(searchText: searchText)
                        for index in indexSet {
                            Task {
                                await viewModel.deleteSecret(filtered[index].id)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                Task { await viewModel.loadSecrets() }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
    }
}

// MARK: - Secret Row View

struct SecretRowView: View {
    let secret: Secret
    let isRevealed: Bool
    let revealedValue: String?
    let autoHideCountdown: Int
    let onRevealTap: () -> Void
    let onHideTap: () -> Void
    let onCopyTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 12) {
                // Category icon
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 40, height: 40)

                    Image(systemName: secret.category.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(secret.name)
                        .font(.headline)

                    Text(secret.category.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Lock/Reveal button
                Button(action: isRevealed ? onHideTap : onRevealTap) {
                    HStack(spacing: 4) {
                        Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")

                        if isRevealed {
                            Text("\(autoHideCountdown)s")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(isRevealed ? .orange : .blue)
                }
            }

            // Revealed value
            if isRevealed, let value = revealedValue {
                VStack(alignment: .leading, spacing: 8) {
                    Text(value)
                        .font(.system(.body, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)

                    HStack {
                        Button(action: onCopyTap) {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        // Auto-hide warning
                        HStack(spacing: 4) {
                            Image(systemName: "clock.fill")
                                .font(.caption)
                            Text("Auto-hides in \(autoHideCountdown)s")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            // Notes
            if let notes = secret.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Metadata
            HStack {
                Text("Updated \(secret.updatedAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Password Prompt Sheet

struct PasswordPromptSheet: View {
    @ObservedObject var viewModel: SecretsViewModel
    @State private var password = ""
    @State private var isVerifying = false
    @FocusState private var isPasswordFieldFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 80, height: 80)

                    Image(systemName: "lock.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                }
                .padding(.top, 20)

                // Title
                VStack(spacing: 8) {
                    Text("Password Required")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Enter your vault password to reveal this secret")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Password field
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .focused($isPasswordFieldFocused)
                        .onSubmit {
                            verifyPassword()
                        }

                    if let error = viewModel.passwordError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal)

                // Note about biometrics
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)

                    Text("Secrets always require password entry for security")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                // Buttons
                VStack(spacing: 12) {
                    Button(action: verifyPassword) {
                        if isVerifying {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Reveal Secret")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || isVerifying)

                    Button("Cancel") {
                        viewModel.cancelPasswordPrompt()
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelPasswordPrompt()
                    }
                }
            }
        }
        .onAppear {
            isPasswordFieldFocused = true
        }
        .presentationDetents([.medium])
    }

    private func verifyPassword() {
        isVerifying = true
        Task {
            await viewModel.verifyPasswordAndReveal(password)
            isVerifying = false
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SecretsView(searchText: "")
    }
}
