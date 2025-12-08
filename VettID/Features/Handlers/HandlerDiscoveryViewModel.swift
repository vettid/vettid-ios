import Foundation
import Combine

/// ViewModel for browsing and managing handlers from the registry
@MainActor
final class HandlerDiscoveryViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: HandlerDiscoveryState = .loading
    @Published var selectedCategory: String? = nil
    @Published private(set) var installingHandlerId: String? = nil
    @Published private(set) var uninstallingHandlerId: String? = nil
    @Published var errorMessage: String? = nil

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let authTokenProvider: @Sendable () -> String?

    // MARK: - Pagination

    private var currentPage = 1
    private let pageSize = 20

    // MARK: - Categories

    static let categories: [(String?, String)] = [
        (nil, "All"),
        ("messaging", "Messaging"),
        ("social", "Social"),
        ("productivity", "Productivity"),
        ("utilities", "Utilities"),
        ("security", "Security"),
        ("integration", "Integration")
    ]

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.apiClient = apiClient
        self.authTokenProvider = authTokenProvider
    }

    // MARK: - Handler Loading

    /// Load handlers from the registry
    func loadHandlers(refresh: Bool = false) async {
        guard let authToken = authTokenProvider() else {
            state = .error("Not authenticated")
            return
        }

        if refresh {
            currentPage = 1
        }

        if currentPage == 1 {
            state = .loading
        }

        do {
            let response = try await apiClient.listHandlers(
                category: selectedCategory,
                page: currentPage,
                limit: pageSize,
                authToken: authToken
            )

            if currentPage == 1 {
                state = .loaded(handlers: response.handlers, hasMore: response.hasMore)
            } else if case .loaded(let existing, _) = state {
                // Append to existing handlers
                state = .loaded(handlers: existing + response.handlers, hasMore: response.hasMore)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Load more handlers (pagination)
    func loadMoreIfNeeded(currentHandler: HandlerSummary) async {
        guard case .loaded(let handlers, let hasMore) = state,
              hasMore,
              let lastHandler = handlers.last,
              currentHandler.id == lastHandler.id else {
            return
        }

        currentPage += 1
        await loadHandlers()
    }

    // MARK: - Category Selection

    /// Select a category and reload handlers
    func selectCategory(_ category: String?) {
        selectedCategory = category
        currentPage = 1
        Task { await loadHandlers(refresh: true) }
    }

    // MARK: - Handler Installation

    /// Install a handler on the vault
    func installHandler(_ handler: HandlerSummary) async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        installingHandlerId = handler.id
        errorMessage = nil

        do {
            let result = try await apiClient.installHandler(
                handlerId: handler.id,
                version: handler.version,
                authToken: authToken
            )

            if result.status == "installed" {
                await loadHandlers(refresh: true)
            } else {
                errorMessage = "Installation failed"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        installingHandlerId = nil
    }

    /// Uninstall a handler from the vault
    func uninstallHandler(_ handler: HandlerSummary) async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        uninstallingHandlerId = handler.id
        errorMessage = nil

        do {
            let result = try await apiClient.uninstallHandler(
                handlerId: handler.id,
                authToken: authToken
            )

            if result.status == "uninstalled" {
                await loadHandlers(refresh: true)
            } else {
                errorMessage = "Uninstall failed"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        uninstallingHandlerId = nil
    }

    // MARK: - Helpers

    /// Check if a handler is being installed
    func isInstalling(_ handler: HandlerSummary) -> Bool {
        installingHandlerId == handler.id
    }

    /// Check if a handler is being uninstalled
    func isUninstalling(_ handler: HandlerSummary) -> Bool {
        uninstallingHandlerId == handler.id
    }

    /// Clear error message
    func clearError() {
        errorMessage = nil
    }
}

// MARK: - Discovery State

enum HandlerDiscoveryState: Equatable {
    case loading
    case loaded(handlers: [HandlerSummary], hasMore: Bool)
    case error(String)

    static func == (lhs: HandlerDiscoveryState, rhs: HandlerDiscoveryState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading):
            return true
        case (.loaded(let h1, let m1), .loaded(let h2, let m2)):
            return h1 == h2 && m1 == m2
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

    var handlers: [HandlerSummary] {
        if case .loaded(let handlers, _) = self {
            return handlers
        }
        return []
    }

    var hasMore: Bool {
        if case .loaded(_, let hasMore) = self {
            return hasMore
        }
        return false
    }
}
