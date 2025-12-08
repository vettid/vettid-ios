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

    /// Update profile with new values
    func updateProfile(_ updatedProfile: Profile) async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isUpdating = true
        errorMessage = nil

        do {
            profile = try await apiClient.updateProfile(updatedProfile, authToken: authToken)
            successMessage = "Profile updated"
            isUpdating = false
        } catch {
            errorMessage = error.localizedDescription
            isUpdating = false
        }
    }

    // MARK: - Publish Profile

    /// Publish profile to all connections
    func publishProfile() async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isPublishing = true
        errorMessage = nil

        do {
            try await apiClient.publishProfile(authToken: authToken)
            successMessage = "Profile published to connections"
            isPublishing = false
        } catch {
            errorMessage = error.localizedDescription
            isPublishing = false
        }
    }

    // MARK: - Error Handling

    func clearError() {
        errorMessage = nil
    }

    func clearSuccess() {
        successMessage = nil
    }
}
