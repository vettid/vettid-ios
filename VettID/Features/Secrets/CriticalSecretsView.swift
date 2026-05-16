import SwiftUI

// MARK: - Critical Secrets View

struct CriticalSecretsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = CriticalSecretsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.state {
            case .passwordPrompt:
                CriticalPasswordPromptView(
                    title: "Enter Vault Password",
                    subtitle: "Password required to view critical secrets",
                    onSubmit: { password in
                        Task { await viewModel.authenticateForMetadata(password: password) }
                    }
                )

            case .authenticating:
                ProgressView("Authenticating...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .metadataList:
                metadataListView

            case .secondPasswordPrompt(let secretId):
                CriticalPasswordPromptView(
                    title: "Confirm Password",
                    subtitle: "Re-enter password to reveal this secret",
                    onSubmit: { password in
                        Task { await viewModel.authenticateAndReveal(secretId: secretId, password: password) }
                    },
                    onCancel: { viewModel.backToMetadataList() }
                )

            case .retrieving:
                ProgressView("Retrieving from vault...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .revealed(let secretId, let value, let countdown):
                revealedView(secretId: secretId, value: value, countdown: countdown)

            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle("Critical Secrets")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Phase 2.1: VM now talks to credential.secret.* via
            // SecretsClient. Wire on first appearance.
            viewModel.client = appState.secretsClient
        }
    }

    // MARK: - Metadata List

    private var metadataListView: some View {
        VStack(spacing: 0) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search secrets...", text: $viewModel.searchText)
            }
            .padding(10)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding()

            // Warning banner
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text("These secrets are fetched from your vault each time. Nothing is cached locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            // List
            List {
                ForEach(viewModel.filteredMetadata) { metadata in
                    Button {
                        viewModel.requestReveal(secretId: metadata.id)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.red.opacity(0.15))
                                    .frame(width: 40, height: 40)
                                Image(systemName: metadata.icon)
                                    .font(.system(size: 18))
                                    .foregroundStyle(.red)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(metadata.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.primary)
                                Text(metadata.category.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "eye.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .listStyle(.plain)

            // Lock button
            Button {
                viewModel.backToPasswordPrompt()
            } label: {
                Label("Lock Critical Secrets", systemImage: "lock.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .padding()
        }
    }

    // MARK: - Revealed View

    private func revealedView(secretId: String, value: String, countdown: Int) -> some View {
        VStack(spacing: 24) {
            Spacer()

            // Countdown warning
            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(0.3), lineWidth: 4)
                    .frame(width: 80, height: 80)
                Circle()
                    .trim(from: 0, to: CGFloat(countdown) / 30.0)
                    .stroke(Color.orange, lineWidth: 4)
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                Text("\(countdown)s")
                    .font(.title2)
                    .fontWeight(.bold)
                    .monospacedDigit()
            }

            // Secret value
            Text(value)
                .font(.system(.body, design: .monospaced))
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)

            // Actions
            HStack(spacing: 16) {
                Button {
                    UIPasteboard.general.string = value
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.hideSecret()
                } label: {
                    Label("Hide Now", systemImage: "eye.slash.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }

            Text("Secret auto-hides in \(countdown) seconds")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.orange)
            Text(message)
                .font(.headline)
            Button("Try Again") {
                viewModel.backToPasswordPrompt()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }
}

// MARK: - Password Prompt (Reusable)

struct CriticalPasswordPromptView: View {
    let title: String
    let subtitle: String
    let onSubmit: (String) -> Void
    var onCancel: (() -> Void)? = nil

    @State private var password = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
            }

            Text(title)
                .font(.title2)
                .fontWeight(.bold)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .padding(.horizontal, 32)
                .onSubmit {
                    guard !password.isEmpty else { return }
                    onSubmit(password)
                }

            Button("Unlock") {
                onSubmit(password)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(password.isEmpty)

            if let onCancel {
                Button("Cancel") { onCancel() }
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .onAppear { isFocused = true }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        CriticalSecretsView()
    }
}
