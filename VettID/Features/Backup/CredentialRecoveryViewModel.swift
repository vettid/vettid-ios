import Foundation

/// ViewModel for credential recovery flow
@MainActor
final class CredentialRecoveryViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: CredentialRecoveryState = .entering
    @Published var enteredWords: [String] = Array(repeating: "", count: 24)
    @Published private(set) var wordValidation: [Bool] = Array(repeating: true, count: 24)
    @Published private(set) var currentSuggestions: [String] = []
    @Published private(set) var focusedIndex: Int? = 0

    // MARK: - Dependencies

    private let recoveryPhraseManager: RecoveryPhraseManager
    private let apiClient: APIClient
    private let credentialStore: CredentialStore
    private let authTokenProvider: @Sendable () -> String?

    // MARK: - Initialization

    init(
        recoveryPhraseManager: RecoveryPhraseManager = RecoveryPhraseManager(),
        apiClient: APIClient = APIClient(),
        credentialStore: CredentialStore = CredentialStore(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.recoveryPhraseManager = recoveryPhraseManager
        self.apiClient = apiClient
        self.credentialStore = credentialStore
        self.authTokenProvider = authTokenProvider
    }

    // MARK: - Public Methods

    /// Set a word at a specific index
    func setWord(_ index: Int, _ word: String) {
        guard index >= 0 && index < 24 else { return }

        let trimmedWord = word.trimmingCharacters(in: .whitespaces).lowercased()
        enteredWords[index] = trimmedWord

        // Validate word
        if trimmedWord.isEmpty {
            wordValidation[index] = true
        } else {
            wordValidation[index] = recoveryPhraseManager.isValidWord(trimmedWord)
        }

        // Update suggestions
        updateSuggestions(for: trimmedWord)
    }

    /// Update focused field index
    func setFocusedIndex(_ index: Int?) {
        focusedIndex = index
        if let index = index {
            updateSuggestions(for: enteredWords[index])
        } else {
            currentSuggestions = []
        }
    }

    /// Apply a suggestion to the current field
    func applySuggestion(_ suggestion: String) {
        guard let index = focusedIndex else { return }
        setWord(index, suggestion)

        // Move to next field
        if index < 23 {
            focusedIndex = index + 1
        }
    }

    /// Check if phrase is valid and complete
    var isPhraseComplete: Bool {
        enteredWords.allSatisfy { !$0.isEmpty } && wordValidation.allSatisfy { $0 }
    }

    /// Recover credentials using entered phrase
    func recoverCredentials() async {
        guard isPhraseComplete else {
            state = .error("Please enter all 24 words correctly")
            return
        }

        // Validate phrase structure
        guard recoveryPhraseManager.validatePhrase(enteredWords) else {
            state = .error("Invalid recovery phrase. Please check the words and try again.")
            return
        }

        state = .validating

        guard let authToken = authTokenProvider() else {
            state = .error("Not authenticated")
            return
        }

        state = .recovering

        do {
            // Download encrypted backup from server
            let encryptedResponse = try await apiClient.downloadCredentialBackup(authToken: authToken)

            guard let ciphertext = Data(base64Encoded: encryptedResponse.encryptedBlob),
                  let salt = Data(base64Encoded: encryptedResponse.salt),
                  let nonce = Data(base64Encoded: encryptedResponse.nonce) else {
                state = .error("Invalid backup data")
                return
            }

            let encryptedBackup = EncryptedCredentialBackup(
                ciphertext: ciphertext,
                salt: salt,
                nonce: nonce
            )

            // Decrypt with recovery phrase
            let credentialBlob = try recoveryPhraseManager.decryptCredentialBackup(
                encryptedBackup,
                phrase: enteredWords
            )

            // Store recovered credentials
            try credentialStore.storeCredentialBlob(credentialBlob)

            state = .complete
        } catch RecoveryPhraseManager.RecoveryPhraseError.decryptionFailed {
            state = .error("Failed to decrypt backup. Please verify your recovery phrase is correct.")
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Reset to initial state
    func reset() {
        enteredWords = Array(repeating: "", count: 24)
        wordValidation = Array(repeating: true, count: 24)
        currentSuggestions = []
        focusedIndex = 0
        state = .entering
    }

    /// Clear all entered words
    func clearAll() {
        enteredWords = Array(repeating: "", count: 24)
        wordValidation = Array(repeating: true, count: 24)
        focusedIndex = 0
    }

    /// Paste phrase from clipboard
    func pastePhrase(_ text: String) {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard words.count == 24 else { return }

        for (index, word) in words.enumerated() {
            setWord(index, word)
        }
    }

    // MARK: - Private Helpers

    private func updateSuggestions(for prefix: String) {
        if prefix.count >= 2 {
            currentSuggestions = recoveryPhraseManager.getSuggestions(for: prefix)
        } else {
            currentSuggestions = []
        }
    }
}
