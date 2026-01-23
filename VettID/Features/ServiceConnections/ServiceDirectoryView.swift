import SwiftUI

/// Service directory browser view
/// Allows users to browse, search, and filter available services
struct ServiceDirectoryView: View {
    @StateObject private var viewModel = ServiceDirectoryViewModel()
    @State private var showingCategoryFilter = false

    var onServiceSelected: ((ServiceDirectoryEntry) -> Void)?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search bar
                searchBar

                // Category filter chips
                categoryFilterBar

                // Content
                content
            }
            .navigationTitle("Service Directory")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    filterButton
                }
            }
        }
        .task {
            await viewModel.loadServices()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search services...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if !viewModel.searchText.isEmpty {
                Button(action: { viewModel.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(10)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Category Filter Bar

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // All categories chip
                CategoryChip(
                    title: "All",
                    icon: nil,
                    isSelected: viewModel.selectedCategory == nil
                ) {
                    viewModel.selectedCategory = nil
                }

                // Individual category chips
                ForEach(ServiceCategory.allCases, id: \.self) { category in
                    CategoryChip(
                        title: category.displayName,
                        icon: category.icon,
                        isSelected: viewModel.selectedCategory == category
                    ) {
                        viewModel.selectedCategory = category
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.services.isEmpty {
            loadingView
        } else if let error = viewModel.errorMessage {
            errorView(error)
        } else if viewModel.services.isEmpty {
            emptyView
        } else {
            serviceList
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading services...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Unable to Load Services")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") {
                Task {
                    await viewModel.refresh()
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "building.2.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Services Found")
                .font(.headline)

            if viewModel.selectedCategory != nil || !viewModel.searchText.isEmpty {
                Text("Try adjusting your search or filters")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button("Clear Filters") {
                    viewModel.clearFilters()
                }
                .buttonStyle(.bordered)
            } else {
                Text("Services will appear here once available")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var serviceList: some View {
        List {
            // Featured section
            let featured = viewModel.services.filter { $0.featured }
            if !featured.isEmpty && viewModel.selectedCategory == nil && viewModel.searchText.isEmpty {
                Section {
                    ForEach(featured) { service in
                        ServiceDirectoryRow(service: service)
                            .onTapGesture {
                                onServiceSelected?(service)
                            }
                            .onAppear {
                                Task {
                                    await viewModel.loadMoreIfNeeded(currentItem: service)
                                }
                            }
                    }
                } header: {
                    Label("Featured", systemImage: "star.fill")
                        .foregroundColor(.orange)
                }
            }

            // All services section
            Section {
                ForEach(viewModel.services.filter { !$0.featured || viewModel.selectedCategory != nil || !viewModel.searchText.isEmpty }) { service in
                    ServiceDirectoryRow(service: service)
                        .onTapGesture {
                            onServiceSelected?(service)
                        }
                        .onAppear {
                            Task {
                                await viewModel.loadMoreIfNeeded(currentItem: service)
                            }
                        }
                }

                if viewModel.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            } header: {
                if !featured.isEmpty && viewModel.selectedCategory == nil && viewModel.searchText.isEmpty {
                    Text("All Services")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Filter Button

    private var filterButton: some View {
        Menu {
            // Sort options
            Section("Sort By") {
                Button {
                    // Sort by name
                } label: {
                    Label("Name", systemImage: "textformat")
                }

                Button {
                    // Sort by popularity
                } label: {
                    Label("Popularity", systemImage: "person.2.fill")
                }

                Button {
                    // Sort by rating
                } label: {
                    Label("Rating", systemImage: "star.fill")
                }
            }

            // Filter options
            Section("Filter") {
                Toggle("Verified Only", isOn: .constant(false))
                Toggle("Featured Only", isOn: .constant(false))
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }
}

// MARK: - Category Chip

struct CategoryChip: View {
    let title: String
    let icon: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.caption)
                }
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor : Color(UIColor.secondarySystemBackground))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Service Directory Row

struct ServiceDirectoryRow: View {
    let service: ServiceDirectoryEntry

    var body: some View {
        HStack(spacing: 16) {
            // Service logo
            serviceLogo

            // Service info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(service.name)
                        .font(.headline)
                        .lineLimit(1)

                    if service.organization.verified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                    }

                    if service.featured {
                        Image(systemName: "star.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                }

                Text(service.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack(spacing: 12) {
                    // Category
                    Label(service.category.displayName, systemImage: service.category.icon)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Connection count
                    if service.connectionCount > 0 {
                        Label(formatConnectionCount(service.connectionCount), systemImage: "person.2.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Rating
                    if let rating = service.rating {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", rating))
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Chevron
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var serviceLogo: some View {
        Group {
            if let logoUrl = service.logoUrl, let url = URL(string: logoUrl) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    placeholderLogo
                }
            } else {
                placeholderLogo
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var placeholderLogo: some View {
        ZStack {
            Color(UIColor.tertiarySystemBackground)
            Image(systemName: service.category.icon)
                .font(.title2)
                .foregroundColor(.secondary)
        }
    }

    private func formatConnectionCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Preview

#if DEBUG
struct ServiceDirectoryView_Previews: PreviewProvider {
    static var previews: some View {
        ServiceDirectoryView()
    }
}
#endif
