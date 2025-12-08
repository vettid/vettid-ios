import SwiftUI

/// Credential recovery view with phrase input
struct CredentialRecoveryView: View {
    let authTokenProvider: @Sendable () -> String?

    @StateObject private var viewModel: CredentialRecoveryViewModel
    @Environment(\.dismiss) private var dismiss

    init(authTokenProvider: @escaping @Sendable () -> String?) {
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: CredentialRecoveryViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        VStack(spacing: 24) {
            switch viewModel.state {
            case .entering:
                RecoveryPhraseInputView(
                    words: $viewModel.enteredWords,
                    wordValidation: viewModel.wordValidation,
                    suggestions: viewModel.currentSuggestions,
                    focusedIndex: viewModel.focusedIndex,
                    onWordChange: { index, word in
                        viewModel.setWord(index, word)
                    },
                    onFocusChange: { index in
                        viewModel.setFocusedIndex(index)
                    },
                    onSuggestionTap: { suggestion in
                        viewModel.applySuggestion(suggestion)
                    },
                    onPaste: { text in
                        viewModel.pastePhrase(text)
                    },
                    onClear: {
                        viewModel.clearAll()
                    },
                    onRecover: {
                        Task { await viewModel.recoverCredentials() }
                    },
                    isRecoverEnabled: viewModel.isPhraseComplete
                )

            case .validating:
                ProgressView("Validating phrase...")

            case .recovering:
                ProgressView("Recovering credentials...")

            case .complete:
                RecoveryCompleteView(onDone: { dismiss() })

            case .error(let message):
                RecoveryErrorView(message: message, onRetry: { viewModel.reset() })
            }
        }
        .padding()
        .navigationTitle("Recover Credentials")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Recovery Phrase Input View

struct RecoveryPhraseInputView: View {
    @Binding var words: [String]
    let wordValidation: [Bool]
    let suggestions: [String]
    let focusedIndex: Int?
    let onWordChange: (Int, String) -> Void
    let onFocusChange: (Int?) -> Void
    let onSuggestionTap: (String) -> Void
    let onPaste: (String) -> Void
    let onClear: () -> Void
    let onRecover: () -> Void
    let isRecoverEnabled: Bool

    @FocusState private var focusedField: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Enter your 24-word recovery phrase")
                    .font(.headline)

                Text("Enter each word in the correct order to recover your credentials.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                // Action buttons
                HStack {
                    Button(action: {
                        if let text = UIPasteboard.general.string {
                            onPaste(text)
                        }
                    }) {
                        Label("Paste", systemImage: "doc.on.clipboard")
                            .font(.caption)
                    }

                    Spacer()

                    Button(action: onClear) {
                        Label("Clear", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                // Word input grid (3x8)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                    ForEach(0..<24, id: \.self) { index in
                        WordInputCell(
                            index: index,
                            word: words[index],
                            isValid: wordValidation[index],
                            isFocused: focusedField == index,
                            onWordChange: { word in
                                onWordChange(index, word)
                            }
                        )
                        .focused($focusedField, equals: index)
                        .onSubmit {
                            if index < 23 {
                                focusedField = index + 1
                            }
                        }
                    }
                }

                // Suggestions
                if !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) {
                                    onSuggestionTap(suggestion)
                                }
                                .buttonStyle(.bordered)
                                .font(.system(.body, design: .monospaced))
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                Spacer(minLength: 20)

                // Recover button
                Button("Recover Credentials") {
                    onRecover()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isRecoverEnabled)
            }
        }
        .onChange(of: focusedField) { newValue in
            onFocusChange(newValue)
        }
        .onAppear {
            focusedField = focusedIndex
        }
    }
}

// MARK: - Word Input Cell

struct WordInputCell: View {
    let index: Int
    let word: String
    let isValid: Bool
    let isFocused: Bool
    let onWordChange: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("\(index + 1).")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .trailing)

            TextField("", text: Binding(
                get: { word },
                set: { onWordChange($0) }
            ))
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .foregroundColor(isValid ? .primary : .red)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isFocused ? Color.blue : (isValid ? Color.clear : Color.red),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
        }
    }
}

// MARK: - Recovery Complete View

struct RecoveryCompleteView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)

            Text("Recovery Complete!")
                .font(.title)
                .fontWeight(.semibold)

            Text("Your credentials have been successfully recovered. You can now access your account.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button("Continue") {
                onDone()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Recovery Error View

struct RecoveryErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text("Recovery Failed")
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

#if DEBUG
struct CredentialRecoveryView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            CredentialRecoveryView(authTokenProvider: { "test-token" })
        }
    }
}
#endif
