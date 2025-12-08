import Foundation

/// ViewModel for credential backup flow
@MainActor
final class CredentialBackupViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: CredentialBackupState = .initial
    @Published private(set) var recoveryPhrase: [String] = []
    @Published private(set) var verifyIndices: [Int] = []

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

    /// Generate a new recovery phrase
    func generateBackup() {
        state = .generating

        // Generate phrase on background thread
        Task {
            let phrase = recoveryPhraseManager.generateRecoveryPhrase()
            recoveryPhrase = phrase
            state = .showingPhrase(phrase)
        }
    }

    /// Confirm user has written down phrase, move to verification
    func confirmWrittenDown() {
        // Select 3 random indices for verification
        var indices: Set<Int> = []
        while indices.count < 3 {
            indices.insert(Int.random(in: 0..<24))
        }
        verifyIndices = indices.sorted()
        state = .verifying(recoveryPhrase, verifyIndices)
    }

    /// Verify user's input and complete backup
    func verifyAndComplete(_ userWords: [String]) async {
        // Check verification words
        for (i, index) in verifyIndices.enumerated() {
            if i < userWords.count && userWords[i].lowercased() != recoveryPhrase[index].lowercased() {
                state = .error("Word \(index + 1) doesn't match. Please try again.")
                return
            }
        }

        await completeBackup()
    }

    /// Complete the backup process
    func completeBackup() async {
        guard let authToken = authTokenProvider() else {
            state = .error("Not authenticated")
            return
        }

        state = .uploading

        do {
            // Get credential blob from store
            guard let credentialBlob = credentialStore.retrieveCredentialBlob() else {
                state = .error("No credentials to backup")
                return
            }

            // Encrypt with recovery phrase
            let encrypted = try recoveryPhraseManager.encryptCredentialBackup(
                credentialBlob,
                phrase: recoveryPhrase
            )

            // Upload to server
            try await apiClient.createCredentialBackup(
                encryptedBlob: encrypted.ciphertext,
                salt: encrypted.salt,
                nonce: encrypted.nonce,
                authToken: authToken
            )

            state = .complete
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Skip verification and complete (for testing/demo)
    func skipVerificationAndComplete() async {
        await completeBackup()
    }

    /// Reset to initial state
    func reset() {
        recoveryPhrase = []
        verifyIndices = []
        state = .initial
    }

    /// Retry from error
    func retry() {
        if recoveryPhrase.isEmpty {
            state = .initial
        } else {
            state = .showingPhrase(recoveryPhrase)
        }
    }
}
