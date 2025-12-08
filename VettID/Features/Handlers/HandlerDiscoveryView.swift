import SwiftUI

/// Main view for browsing and discovering handlers
struct HandlerDiscoveryView: View {
    @StateObject var viewModel: HandlerDiscoveryViewModel
    @State private var selectedHandler: HandlerSummary?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Category picker
                CategoryPicker(
                    selectedCategory: $viewModel.selectedCategory,
                    categories: HandlerDiscoveryViewModel.categories,
                    onSelect: { viewModel.selectCategory($0) }
                )

                // Handler list
                contentView
            }
            .navigationTitle("Handlers")
            .sheet(item: $selectedHandler) { handler in
                HandlerDetailView(
                    handlerId: handler.id,
                    authTokenProvider: { nil } // Will be replaced with actual provider
                )
            }
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.clearError() }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
        .task {
            await viewModel.loadHandlers()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let handlers, let hasMore):
            if handlers.isEmpty {
                EmptyHandlersView(category: viewModel.selectedCategory)
            } else {
                List {
                    ForEach(handlers) { handler in
                        HandlerListRow(
                            handler: handler,
                            isInstalling: viewModel.isInstalling(handler),
                            isUninstalling: viewModel.isUninstalling(handler),
                            onTap: { selectedHandler = handler },
                            onInstall: { Task { await viewModel.installHandler(handler) } },
                            onUninstall: { Task { await viewModel.uninstallHandler(handler) } }
                        )
                        .onAppear {
                            Task { await viewModel.loadMoreIfNeeded(currentHandler: handler) }
                        }
                    }

                    if hasMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await viewModel.loadHandlers(refresh: true)
                }
            }

        case .error(let message):
            ErrorView(message: message) {
                Task { await viewModel.loadHandlers(refresh: true) }
            }
        }
    }
}

// MARK: - Category Picker

struct CategoryPicker: View {
    @Binding var selectedCategory: String?
    let categories: [(String?, String)]
    let onSelect: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(categories, id: \.0) { category, label in
                    CategoryChip(
                        label: label,
                        isSelected: selectedCategory == category,
                        action: { onSelect(category) }
                    )
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
}

struct CategoryChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue : Color(.systemGray6))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(20)
        }
    }
}

// MARK: - Handler List Row

struct HandlerListRow: View {
    let handler: HandlerSummary
    let isInstalling: Bool
    let isUninstalling: Bool
    let onTap: () -> Void
    let onInstall: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Handler icon
            AsyncImage(url: URL(string: handler.iconUrl ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .failure, .empty:
                    Image(systemName: "cube.box")
                        .font(.title2)
                        .foregroundColor(.secondary)
                @unknown default:
                    Image(systemName: "cube.box")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .background(Color(.systemGray6))
            .cornerRadius(8)

            // Handler info
            VStack(alignment: .leading, spacing: 4) {
                Text(handler.name)
                    .font(.headline)

                Text(handler.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text("v\(handler.version)")
                    Text("by \(handler.publisher)")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Action button
            actionButton
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isInstalling || isUninstalling {
            ProgressView()
                .frame(width: 80)
        } else if handler.installed {
            Button("Uninstall", action: onUninstall)
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else {
            Button("Install", action: onInstall)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

// MARK: - Empty State

struct EmptyHandlersView: View {
    let category: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.box")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Handlers Found")
                .font(.title2)
                .fontWeight(.semibold)

            if let category = category {
                Text("No handlers available in the \(category) category.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Check back later for new handlers.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

#if DEBUG
struct HandlerDiscoveryView_Previews: PreviewProvider {
    static var previews: some View {
        Text("HandlerDiscoveryView Preview")
    }
}
#endif
