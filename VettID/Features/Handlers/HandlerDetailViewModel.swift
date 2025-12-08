import Foundation
import Combine

/// ViewModel for displaying handler details
@MainActor
final class HandlerDetailViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: HandlerDetailState = .loading
    @Published private(set) var isInstalling: Bool = false
    @Published private(set) var isUninstalling: Bool = false
    @Published var showExecutionSheet: Bool = false
    @Published var errorMessage: String? = nil

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let authTokenProvider: @Sendable () -> String?

    // MARK: - State

    private var handlerId: String?

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.apiClient = apiClient
        self.authTokenProvider = authTokenProvider
    }

    // MARK: - Handler Loading

    /// Load handler details
    func loadHandler(_ handlerId: String) async {
        guard let authToken = authTokenProvider() else {
            state = .error("Not authenticated")
            return
        }

        self.handlerId = handlerId
        state = .loading

        do {
            let handler = try await apiClient.getHandler(id: handlerId, authToken: authToken)
            state = .loaded(handler)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Handler Installation

    /// Install the current handler
    func installHandler() async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        guard case .loaded(let handler) = state else { return }

        isInstalling = true
        errorMessage = nil

        do {
            let result = try await apiClient.installHandler(
                handlerId: handler.id,
                version: handler.version,
                authToken: authToken
            )

            if result.status == "installed" {
                // Reload to get updated installed status
                await loadHandler(handler.id)
            } else {
                errorMessage = "Installation failed"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isInstalling = false
    }

    /// Uninstall the current handler
    func uninstallHandler() async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        guard case .loaded(let handler) = state else { return }

        isUninstalling = true
        errorMessage = nil

        do {
            let result = try await apiClient.uninstallHandler(
                handlerId: handler.id,
                authToken: authToken
            )

            if result.status == "uninstalled" {
                // Reload to get updated installed status
                await loadHandler(handler.id)
            } else {
                errorMessage = "Uninstall failed"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isUninstalling = false
    }

    // MARK: - Helpers

    /// Get the current handler if loaded
    var currentHandler: HandlerDetailResponse? {
        if case .loaded(let handler) = state {
            return handler
        }
        return nil
    }

    /// Clear error message
    func clearError() {
        errorMessage = nil
    }
}

// MARK: - Detail State

enum HandlerDetailState: Equatable {
    case loading
    case loaded(HandlerDetailResponse)
    case error(String)

    static func == (lhs: HandlerDetailState, rhs: HandlerDetailState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading):
            return true
        case (.loaded(let h1), .loaded(let h2)):
            return h1.id == h2.id && h1.version == h2.version
        case (.error(let e1), .error(let e2)):
            return e1 == e2
        default:
            return false
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
