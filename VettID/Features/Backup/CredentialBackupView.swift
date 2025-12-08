import SwiftUI

/// Credential backup view with recovery phrase
struct CredentialBackupView: View {
    let authTokenProvider: @Sendable () -> String?

    @StateObject private var viewModel: CredentialBackupViewModel
    @Environment(\.dismiss) private var dismiss

    init(authTokenProvider: @escaping @Sendable () -> String?) {
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: CredentialBackupViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        VStack(spacing: 24) {
            switch viewModel.state {
            case .initial:
                InitialBackupView(onGenerate: { viewModel.generateBackup() })

            case .generating:
                ProgressView("Generating recovery phrase...")

            case .showingPhrase(let words):
                RecoveryPhraseDisplayView(
                    words: words,
                    onConfirm: { viewModel.confirmWrittenDown() }
                )

            case .verifying(let words, let verifyIndices):
                RecoveryPhraseVerifyView(
                    originalWords: words,
                    verifyIndices: verifyIndices,
                    onVerify: { userWords in
                        Task { await viewModel.verifyAndComplete(userWords) }
                    }
                )

            case .uploading:
                ProgressView("Uploading backup...")

            case .complete:
                BackupCompleteView(onDone: { dismiss() })

            case .error(let message):
                BackupErrorView(message: message, onRetry: { viewModel.retry() })
            }
        }
        .padding()
        .navigationTitle("Credential Backup")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Initial Backup View

struct InitialBackupView: View {
    let onGenerate: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "key.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("Backup Your Credentials")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Generate a 24-word recovery phrase to backup your credentials. You'll need this phrase to restore your account on a new device.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            WarningBanner(
                message: "Keep your recovery phrase safe and never share it with anyone."
            )

            Spacer()

            Button("Generate Recovery Phrase") {
                onGenerate()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Recovery Phrase Display View

struct RecoveryPhraseDisplayView: View {
    let words: [String]
    let onConfirm: () -> Void
    @State private var showCopied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Warning
                WarningBanner(
                    message: "Write down these 24 words in order. Never share them with anyone."
                )

                // Word grid (4x6)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        HStack(spacing: 4) {
                            Text("\(index + 1).")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 18, alignment: .trailing)
                            Text(word)
                                .font(.system(.body, design: .monospaced))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                }

                // Copy button
                Button(action: {
                    UIPasteboard.general.string = words.joined(separator: " ")
                    showCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showCopied = false
                    }
                }) {
                    Label(
                        showCopied ? "Copied!" : "Copy to Clipboard",
                        systemImage: showCopied ? "checkmark" : "doc.on.doc"
                    )
                }
                .foregroundColor(.blue)

                Spacer(minLength: 20)

                // Confirm button
                Button("I've Written It Down") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Recovery Phrase Verify View

struct RecoveryPhraseVerifyView: View {
    let originalWords: [String]
    let verifyIndices: [Int]
    let onVerify: ([String]) -> Void

    @State private var userWords: [String]
    @FocusState private var focusedField: Int?

    init(originalWords: [String], verifyIndices: [Int], onVerify: @escaping ([String]) -> Void) {
        self.originalWords = originalWords
        self.verifyIndices = verifyIndices
        self.onVerify = onVerify
        self._userWords = State(initialValue: Array(repeating: "", count: verifyIndices.count))
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Verify Your Recovery Phrase")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Enter the following words from your recovery phrase to verify you've saved it correctly.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 16) {
                ForEach(Array(verifyIndices.enumerated()), id: \.offset) { i, wordIndex in
                    HStack {
                        Text("Word \(wordIndex + 1):")
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)

                        TextField("Enter word", text: $userWords[i])
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .focused($focusedField, equals: i)
                            .onSubmit {
                                if i < verifyIndices.count - 1 {
                                    focusedField = i + 1
                                }
                            }
                    }
                }
            }
            .padding()

            Spacer()

            Button("Verify") {
                onVerify(userWords)
            }
            .buttonStyle(.borderedProminent)
            .disabled(userWords.contains { $0.isEmpty })
        }
        .onAppear {
            focusedField = 0
        }
    }
}

// MARK: - Backup Complete View

struct BackupCompleteView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)

            Text("Backup Complete!")
                .font(.title)
                .fontWeight(.semibold)

            Text("Your credentials have been securely backed up. Keep your recovery phrase in a safe place.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button("Done") {
                onDone()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Backup Error View

struct BackupErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text("Backup Failed")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button("Try Again") {
                onRetry()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Warning Banner

struct WarningBanner: View {
    let message: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
}

#if DEBUG
struct CredentialBackupView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            CredentialBackupView(authTokenProvider: { "test-token" })
        }
    }
}
#endif
