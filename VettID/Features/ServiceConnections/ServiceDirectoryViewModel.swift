import Foundation
import Combine

/// ViewModel for the service directory browser
@MainActor
final class ServiceDirectoryViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var services: [ServiceDirectoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMorePages = true
    @Published var errorMessage: String?

    // MARK: - Search & Filter

    @Published var searchText = ""
    @Published var selectedCategory: ServiceCategory?

    // MARK: - Pagination

    private var currentPage = 1
    private let pageSize = 20

    // MARK: - Dependencies

    private let apiClient: APIClient
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
        setupSearchDebounce()
    }

    // MARK: - Setup

    private func setupSearchDebounce() {
        // Debounce search input to avoid excessive API calls
        $searchText
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                Task {
                    await self?.refresh()
                }
            }
            .store(in: &cancellables)

        // Refresh when category changes
        $selectedCategory
            .dropFirst()
            .sink { [weak self] _ in
                Task {
                    await self?.refresh()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Loading

    /// Load initial services
    func loadServices() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        currentPage = 1

        do {
            let response = try await fetchServices(page: 1)
            services = response.services
            hasMorePages = response.hasMore
            currentPage = 1
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Refresh the service list
    func refresh() async {
        // Cancel any pending search
        searchTask?.cancel()

        searchTask = Task {
            guard !Task.isCancelled else { return }
            await loadServices()
        }
    }

    /// Load more services (pagination)
    func loadMoreIfNeeded(currentItem: ServiceDirectoryEntry?) async {
        guard let currentItem = currentItem,
              !isLoadingMore,
              hasMorePages else { return }

        // Load more when approaching the end
        let thresholdIndex = services.index(services.endIndex, offsetBy: -5)
        guard let itemIndex = services.firstIndex(where: { $0.id == currentItem.id }),
              itemIndex >= thresholdIndex else { return }

        isLoadingMore = true

        do {
            let response = try await fetchServices(page: currentPage + 1)
            services.append(contentsOf: response.services)
            hasMorePages = response.hasMore
            currentPage += 1
        } catch {
            #if DEBUG
            print("[ServiceDirectory] Failed to load more: \(error)")
            #endif
        }

        isLoadingMore = false
    }

    // MARK: - API

    private func fetchServices(page: Int) async throws -> ServiceDirectoryResponse {
        // For now, return mock data since the API endpoint isn't implemented yet
        // In production, this would call: apiClient.listServices(...)
        #if DEBUG
        return mockServiceDirectory(page: page)
        #else
        throw ServiceDirectoryError.notImplemented
        #endif
    }

    // MARK: - Helpers

    /// Get categories with service counts
    var categoriesWithCounts: [(category: ServiceCategory, count: Int)] {
        var counts: [ServiceCategory: Int] = [:]

        for service in services {
            counts[service.category, default: 0] += 1
        }

        return ServiceCategory.allCases
            .map { ($0, counts[$0] ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    /// Clear search and filters
    func clearFilters() {
        searchText = ""
        selectedCategory = nil
    }

    // MARK: - Mock Data (Development)

    #if DEBUG
    private func mockServiceDirectory(page: Int) -> ServiceDirectoryResponse {
        // Simulate network delay
        let mockServices: [ServiceDirectoryEntry] = [
            ServiceDirectoryEntry(
                id: "service-1",
                name: "Example Bank",
                description: "Secure banking services with VettID integration",
                logoUrl: nil,
                category: .finance,
                organization: OrganizationInfo(
                    name: "Example Bank Inc.",
                    verified: true,
                    verificationType: .business,
                    verifiedAt: Date(),
                    registrationId: "BNK-12345",
                    country: "US"
                ),
                connectionCount: 15420,
                rating: 4.8,
                featured: true
            ),
            ServiceDirectoryEntry(
                id: "service-2",
                name: "HealthFirst Clinic",
                description: "Healthcare provider with secure patient records",
                logoUrl: nil,
                category: .healthcare,
                organization: OrganizationInfo(
                    name: "HealthFirst Medical Group",
                    verified: true,
                    verificationType: .business,
                    verifiedAt: Date(),
                    registrationId: "HLT-54321",
                    country: "US"
                ),
                connectionCount: 8340,
                rating: 4.6,
                featured: false
            ),
            ServiceDirectoryEntry(
                id: "service-3",
                name: "City Government Portal",
                description: "Municipal services and document verification",
                logoUrl: nil,
                category: .government,
                organization: OrganizationInfo(
                    name: "City of Example",
                    verified: true,
                    verificationType: .government,
                    verifiedAt: Date(),
                    registrationId: "GOV-00001",
                    country: "US"
                ),
                connectionCount: 42100,
                rating: 4.2,
                featured: true
            ),
            ServiceDirectoryEntry(
                id: "service-4",
                name: "TechStore Pro",
                description: "Electronics retailer with secure checkout",
                logoUrl: nil,
                category: .retail,
                organization: OrganizationInfo(
                    name: "TechStore Inc.",
                    verified: true,
                    verificationType: .business,
                    verifiedAt: Date(),
                    registrationId: "RET-98765",
                    country: "US"
                ),
                connectionCount: 5630,
                rating: 4.4,
                featured: false
            ),
            ServiceDirectoryEntry(
                id: "service-5",
                name: "University Portal",
                description: "Student services and academic records",
                logoUrl: nil,
                category: .education,
                organization: OrganizationInfo(
                    name: "State University",
                    verified: true,
                    verificationType: .nonprofit,
                    verifiedAt: Date(),
                    registrationId: "EDU-11111",
                    country: "US"
                ),
                connectionCount: 12890,
                rating: 4.5,
                featured: false
            )
        ]

        // Filter by search text
        var filtered = mockServices
        if !searchText.isEmpty {
            let search = searchText.lowercased()
            filtered = filtered.filter {
                $0.name.lowercased().contains(search) ||
                $0.description.lowercased().contains(search) ||
                $0.organization.name.lowercased().contains(search)
            }
        }

        // Filter by category
        if let category = selectedCategory {
            filtered = filtered.filter { $0.category == category }
        }

        return ServiceDirectoryResponse(
            services: filtered,
            total: filtered.count,
            page: page,
            hasMore: false
        )
    }
    #endif
}

// MARK: - Service Directory Entry

/// Entry in the service directory
struct ServiceDirectoryEntry: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let logoUrl: String?
    let category: ServiceCategory
    let organization: OrganizationInfo
    let connectionCount: Int
    let rating: Double?
    let featured: Bool

    enum CodingKeys: String, CodingKey {
        case id = "service_id"
        case name = "service_name"
        case description
        case logoUrl = "logo_url"
        case category
        case organization
        case connectionCount = "connection_count"
        case rating
        case featured
    }
}

// MARK: - Service Directory Response

/// Response from the service directory API
struct ServiceDirectoryResponse: Codable {
    let services: [ServiceDirectoryEntry]
    let total: Int
    let page: Int
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case services
        case total
        case page
        case hasMore = "has_more"
    }
}

// MARK: - Errors

enum ServiceDirectoryError: Error, LocalizedError {
    case notImplemented
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Service directory is not yet available"
        case .loadFailed(let reason):
            return "Failed to load services: \(reason)"
        }
    }
}
