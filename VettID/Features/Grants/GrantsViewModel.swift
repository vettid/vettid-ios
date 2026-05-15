import Foundation
import SwiftUI
import Combine

// MARK: - Grants View Model

/// Thin mirror of `GrantsRepository`'s published state. Lives separately
/// from the repository so the view can re-subscribe / re-hydrate without
/// poking at the singleton's lifecycle, and so future per-tab filtering
/// has a natural home.
@MainActor
final class GrantsViewModel: ObservableObject {

    @Published private(set) var pending: [PendingRequestSummary] = []
    @Published private(set) var outbound: [GrantSummary] = []
    @Published private(set) var inbound: [GrantSummary] = []
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?

    private let repository: GrantsRepository
    private var cancellables: Set<AnyCancellable> = []

    init(repository: GrantsRepository = .shared) {
        self.repository = repository

        // Mirror the repository's published collections.
        repository.$pending
            .receive(on: RunLoop.main)
            .assign(to: \.pending, on: self)
            .store(in: &cancellables)
        repository.$outbound
            .receive(on: RunLoop.main)
            .assign(to: \.outbound, on: self)
            .store(in: &cancellables)
        repository.$inbound
            .receive(on: RunLoop.main)
            .assign(to: \.inbound, on: self)
            .store(in: &cancellables)
        repository.$lastError
            .receive(on: RunLoop.main)
            .assign(to: \.errorMessage, on: self)
            .store(in: &cancellables)
    }

    /// Trigger a fresh hydrate. Idempotent. Called from `.task` and
    /// `.refreshable` on `GrantsView`.
    func load() async {
        isLoading = true
        await repository.hydrate()
        isLoading = false
    }
}
