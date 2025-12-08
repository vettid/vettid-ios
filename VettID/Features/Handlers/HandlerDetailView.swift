import SwiftUI

/// View for displaying handler details with permissions and actions
struct HandlerDetailView: View {
    let handlerId: String
    let authTokenProvider: () -> String?

    @StateObject private var viewModel: HandlerDetailViewModel
    @Environment(\.dismiss) private var dismiss

    init(handlerId: String, authTokenProvider: @escaping () -> String?) {
        self.handlerId = handlerId
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: HandlerDetailViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        NavigationView {
            Group {
                switch viewModel.state {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .loaded(let handler):
                    HandlerDetailContent(
                        handler: handler,
                        isInstalling: viewModel.isInstalling,
                        isUninstalling: viewModel.isUninstalling,
                        onInstall: { Task { await viewModel.installHandler() } },
                        onUninstall: { Task { await viewModel.uninstallHandler() } },
                        onExecute: { viewModel.showExecutionSheet = true }
                    )

                case .error(let message):
                    ErrorView(message: message) {
                        Task { await viewModel.loadHandler(handlerId) }
                    }
                }
            }
            .navigationTitle("Handler Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.clearError() }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
        .sheet(isPresented: $viewModel.showExecutionSheet) {
            if let handler = viewModel.currentHandler {
                HandlerExecutionView(
                    handler: handler,
                    authTokenProvider: authTokenProvider
                )
            }
        }
        .task {
            await viewModel.loadHandler(handlerId)
        }
    }
}

// MARK: - Detail Content

struct HandlerDetailContent: View {
    let handler: HandlerDetailResponse
    let isInstalling: Bool
    let isUninstalling: Bool
    let onInstall: () -> Void
    let onUninstall: () -> Void
    let onExecute: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                // Description
                Text(handler.description)
                    .font(.body)

                // Permissions section
                permissionsSection

                // Metadata section
                metadataSection

                // Action buttons
                actionButtons

                // Changelog
                changelogSection
            }
            .padding()
        }
    }

    private var headerSection: some View {
        HStack(spacing: 16) {
            AsyncImage(url: URL(string: handler.iconUrl ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .failure, .empty:
                    Image(systemName: "cube.box")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                @unknown default:
                    Image(systemName: "cube.box")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .background(Color(.systemGray6))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 4) {
                Text(handler.name)
                    .font(.title2)
                    .fontWeight(.bold)

                Text("v\(handler.version) by \(handler.publisher)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if handler.installed {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            Spacer()
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)

            if handler.permissions.isEmpty {
                Text("No special permissions required")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(handler.permissions, id: \.type) { permission in
                        PermissionRow(permission: permission)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.headline)

            HStack {
                MetadataItem(title: "Category", value: handler.category.capitalized)
                Spacer()
                MetadataItem(title: "Size", value: formatSize(handler.sizeBytes))
            }
        }
    }

    private var actionButtons: some View {
        Group {
            if handler.installed {
                HStack(spacing: 12) {
                    Button(action: onExecute) {
                        Label("Execute", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: onUninstall) {
                        if isUninstalling {
                            ProgressView()
                        } else {
                            Label("Uninstall", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isUninstalling)
                }
            } else {
                Button(action: onInstall) {
                    if isInstalling {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Install", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling)
            }
        }
    }

    @ViewBuilder
    private var changelogSection: some View {
        if let changelog = handler.changelog, !changelog.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Changelog")
                    .font(.headline)

                Text(changelog)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let permission: HandlerPermission

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconForPermission(permission.type))
                .foregroundColor(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.type.capitalized)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(permission.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !permission.scope.isEmpty {
                    Text("Scope: \(permission.scope)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }

    private func iconForPermission(_ type: String) -> String {
        switch type.lowercased() {
        case "network": return "network"
        case "storage": return "externaldrive"
        case "crypto": return "lock.shield"
        case "filesystem": return "folder"
        case "clipboard": return "doc.on.clipboard"
        default: return "questionmark.circle"
        }
    }
}

// MARK: - Metadata Item

struct MetadataItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Previews

#if DEBUG
struct HandlerDetailView_Previews: PreviewProvider {
    static var previews: some View {
        Text("HandlerDetailView Preview")
    }
}
#endif
