import Foundation

/// ViewModel for profile screen
@MainActor
final class ProfileViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var profile: Profile?
    @Published private(set) var isLoading = true
    @Published private(set) var isPublishing = false
    @Published private(set) var isUpdating = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let authTokenProvider: @Sendable () -> String?

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.apiClient = apiClient
        self.authTokenProvider = authTokenProvider
    }

    // MARK: - Loading

    /// Load profile from API
    func loadProfile() async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            profile = try await apiClient.getProfile(authToken: authToken)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Update Profile

    /// Update profile with new values, then auto-publish to connections
    /// (Phase 2.9). The vault is the single source of truth — every
    /// mutator funnels through here, and a successful update implicitly
    /// re-publishes the public snapshot. No more separate "Publish"
    /// button to forget about.
    func updateProfile(_ updatedProfile: Profile) async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isUpdating = true
        errorMessage = nil

        do {
            profile = try await apiClient.updateProfile(updatedProfile, authToken: authToken)
            isUpdating = false
            // Auto-publish — fan-out happens in the background so the
            // save UI doesn't block on the broadcast. We surface
            // failure quietly via errorMessage rather than rolling back
            // the local update; on retry the vault re-broadcasts.
            await autoPublish()
        } catch {
            errorMessage = error.localizedDescription
            isUpdating = false
        }
    }

    // MARK: - Auto-Publish (Phase 2.9)

    /// Fan-out the published-profile snapshot. Called automatically
    /// after every successful update; the manual "Publish to
    /// Connections" button on `ProfileView` is gone.
    ///
    /// Errors are surfaced through `errorMessage` but don't reset the
    /// local profile — the vault will re-broadcast the latest state on
    /// its next opportunity, and the user can pull-to-refresh to see
    /// the result.
    private func autoPublish() async {
        guard let authToken = authTokenProvider() else { return }
        isPublishing = true
        do {
            try await apiClient.publishProfile(authToken: authToken)
        } catch {
            errorMessage = error.localizedDescription
        }
        isPublishing = false
    }

    // MARK: - Error Handling

    func clearError() {
        errorMessage = nil
    }

    func clearSuccess() {
        successMessage = nil
    }
}
