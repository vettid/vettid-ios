import SwiftUI

/// Detail view for a service connection
struct ServiceConnectionDetailView: View {
    @StateObject private var viewModel: ServiceConnectionDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingPasswordPrompt = false

    init(connectionId: String, serviceConnectionHandler: ServiceConnectionHandler) {
        self._viewModel = StateObject(wrappedValue: ServiceConnectionDetailViewModel(
            connectionId: connectionId,
            serviceConnectionHandler: serviceConnectionHandler
        ))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                loadingView

            case .loaded(let connection):
                loadedView(connection)

            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle(viewModel.connection?.serviceProfile.serviceName ?? "Service")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: {
                        Task { await viewModel.toggleFavorite() }
                    }) {
                        Label(
                            viewModel.connection?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: viewModel.connection?.isFavorite == true ? "star.slash" : "star"
                        )
                    }

                    Button(action: {
                        Task { await viewModel.toggleMuted() }
                    }) {
                        Label(
                            viewModel.connection?.isMuted == true ? "Unmute" : "Mute",
                            systemImage: viewModel.connection?.isMuted == true ? "bell" : "bell.slash"
                        )
                    }

                    Button(action: {
                        Task { await viewModel.archiveConnection() }
                    }) {
                        Label("Archive", systemImage: "archivebox")
                    }

                    Divider()

                    Button(role: .destructive, action: {
                        viewModel.showingRevokeConfirmation = true
                    }) {
                        Label("Revoke Connection", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Revoke Connection?", isPresented: $viewModel.showingRevokeConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) {
                showingPasswordPrompt = true
            }
        } message: {
            Text("This will immediately terminate your connection with this service. You will need to reconnect to use this service again.")
        }
        .sheet(isPresented: $showingPasswordPrompt) {
            RevokeConnectionPasswordPrompt(
                serviceName: viewModel.connection?.serviceProfile.serviceName ?? "this service",
                isRevoking: viewModel.isRevoking,
                onAuthorize: { password in
                    await viewModel.revokeConnectionWithPassword(password)
                    if viewModel.errorMessage == nil {
                        showingPasswordPrompt = false
                        dismiss()
                    }
                },
                onCancel: {
                    showingPasswordPrompt = false
                }
            )
            .interactiveDismissDisabled(viewModel.isRevoking)
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.clearError() }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .task {
            await viewModel.loadConnection()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack {
            ProgressView()
            Text("Loading service details...")
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
    }

    // MARK: - Loaded View

    private func loadedView(_ connection: ServiceConnectionRecord) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                // Service Profile Header
                ServiceProfileCard(profile: connection.serviceProfile, compact: false)
                    .padding(.horizontal)

                // Contract Update Banner
                if connection.pendingContractVersion != nil {
                    ContractUpdateBanner(
                        currentVersion: connection.contractVersion,
                        newVersion: connection.pendingContractVersion ?? 0,
                        onReview: { viewModel.showingContractUpdate = true }
                    )
                    .padding(.horizontal)
                }

                // Connection Health
                if let health = viewModel.health {
                    ConnectionHealthSection(health: health)
                        .padding(.horizontal)
                }

                // Shared Data Summary
                ServiceSharedDataSection(connection: connection, dataSummary: viewModel.dataSummary)
                    .padding(.horizontal)

                // Activity Summary
                if let summary = viewModel.activitySummary {
                    ActivitySummarySection(summary: summary, recentActivities: viewModel.activities)
                        .padding(.horizontal)
                }

                // Trusted Resources
                if !viewModel.trustedResources.isEmpty {
                    TrustedResourcesSection(resources: viewModel.trustedResources)
                        .padding(.horizontal)
                }

                // Contract Info
                ContractInfoSection(connection: connection)
                    .padding(.horizontal)

                // Connection Info
                ServiceConnectionInfoSection(connection: connection)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.red)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Contract Update Banner

struct ContractUpdateBanner: View {
    let currentVersion: Int
    let newVersion: Int
    let onReview: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Contract Update Available")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("v\(currentVersion) → v\(newVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Review", action: onReview)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - Connection Health Section

struct ConnectionHealthSection: View {
    let health: ServiceConnectionHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connection Health")
                    .font(.headline)
                Spacer()
                HealthStatusBadge(status: health.status)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                HealthMetricItem(
                    icon: "clock",
                    title: "Last Active",
                    value: health.lastActiveAt?.formatted(.relative(presentation: .named)) ?? "Never"
                )

                HealthMetricItem(
                    icon: "doc.text",
                    title: "Contract",
                    value: health.contractStatus.displayName
                )

                HealthMetricItem(
                    icon: "externaldrive",
                    title: "Storage",
                    value: "\(Int(health.storageUsagePercent * 100))%"
                )

                HealthMetricItem(
                    icon: "arrow.up.arrow.down",
                    title: "Requests/hr",
                    value: "\(health.requestsThisHour)/\(health.requestLimit)"
                )
            }

            if !health.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(health.issues, id: \.self) { issue in
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text(issue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct HealthStatusBadge: View {
    let status: ConnectionHealthStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon)
            Text(status.displayName)
        }
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .cornerRadius(8)
    }

    private var color: Color {
        switch status {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

struct HealthMetricItem: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Spacer()
        }
        .padding(10)
        .background(Color(UIColor.tertiarySystemBackground))
        .cornerRadius(8)
    }
}

// MARK: - Shared Data Section

struct ServiceSharedDataSection: View {
    let connection: ServiceConnectionRecord
    let dataSummary: ServiceDataSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Shared Data")
                    .font(.headline)
                Spacer()
                NavigationLink(destination: Text("Data Details")) {
                    Text("View All")
                        .font(.caption)
                }
            }

            ForEach(connection.sharedFields) { mapping in
                HStack {
                    Image(systemName: mapping.fieldSpec.fieldType.icon)
                        .foregroundColor(.blue)
                        .frame(width: 24)

                    Text(mapping.fieldSpec.fieldType.displayLabel)
                        .font(.subheadline)

                    Spacer()

                    if let updated = mapping.lastUpdatedAt {
                        Text(updated, style: .relative)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let summary = dataSummary, summary.totalItems > 0 {
                Divider()

                HStack {
                    Text("Service Storage:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(summary.totalItems) items (\(summary.formattedSize))")
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Activity Summary Section

struct ActivitySummarySection: View {
    let summary: ServiceActivitySummary
    let recentActivities: [ServiceActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Spacer()
                NavigationLink(destination: Text("Activity Details")) {
                    Text("View All")
                        .font(.caption)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ActivityStatItem(title: "Data Requests", value: "\(summary.totalDataRequests)")
                ActivityStatItem(title: "Data Stored", value: "\(summary.totalDataStored)")
                ActivityStatItem(title: "Auth Requests", value: "\(summary.totalAuthRequests)")
                ActivityStatItem(title: "Payments", value: "\(summary.totalPayments)")
            }

            if !recentActivities.isEmpty {
                Divider()

                Text("Recent Activity")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(recentActivities.prefix(3)) { activity in
                    HStack {
                        Image(systemName: activity.type.icon)
                            .foregroundColor(.secondary)
                            .frame(width: 20)

                        Text(activity.description)
                            .font(.caption)
                            .lineLimit(1)

                        Spacer()

                        Text(activity.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct ActivityStatItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color(UIColor.tertiarySystemBackground))
        .cornerRadius(8)
    }
}

// MARK: - Trusted Resources Section

struct TrustedResourcesSection: View {
    let resources: [TrustedResource]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trusted Resources")
                .font(.headline)

            ForEach(resources) { resource in
                HStack {
                    Image(systemName: resource.type.icon)
                        .foregroundColor(.blue)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(resource.label)
                            .font(.subheadline)
                        Text(resource.url)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if let url = URL(string: resource.url) {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Contract Info Section

struct ContractInfoSection: View {
    let connection: ServiceConnectionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Contract")
                .font(.headline)

            HStack {
                Text("Version")
                    .foregroundColor(.secondary)
                Spacer()
                Text("v\(connection.contractVersion)")
            }
            .font(.subheadline)

            HStack {
                Text("Accepted")
                    .foregroundColor(.secondary)
                Spacer()
                Text(connection.contractAcceptedAt, style: .date)
            }
            .font(.subheadline)

            NavigationLink(destination: Text("Contract Details")) {
                Text("View Full Contract")
                    .font(.subheadline)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Connection Info Section

struct ServiceConnectionInfoSection: View {
    let connection: ServiceConnectionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection Info")
                .font(.headline)

            HStack {
                Text("Status")
                    .foregroundColor(.secondary)
                Spacer()
                ServiceConnectionStatusBadge(status: connection.status)
            }
            .font(.subheadline)

            HStack {
                Text("Connected Since")
                    .foregroundColor(.secondary)
                Spacer()
                Text(connection.createdAt, style: .date)
            }
            .font(.subheadline)

            if !connection.tags.isEmpty {
                HStack(alignment: .top) {
                    Text("Tags")
                        .foregroundColor(.secondary)
                    Spacer()
                    FlowLayout(spacing: 4) {
                        ForEach(connection.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var maxHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += maxHeight + spacing
                    maxHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                maxHeight = max(maxHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + maxHeight)
        }
    }
}

// MARK: - Revoke Connection Password Prompt

/// Password prompt for revoking a service connection
struct RevokeConnectionPasswordPrompt: View {
    let serviceName: String
    let isRevoking: Bool
    let onAuthorize: (String) async -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var errorMessage: String?
    @State private var showPassword = false
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Warning icon and info
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)

                    Text("Revoke Connection")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Enter your password to permanently disconnect from \(serviceName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top)

                // Warning box
                HStack {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("This action cannot be undone. You will need to reconnect to use this service again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)

                // Password field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Password")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack {
                        if showPassword {
                            TextField("Enter password", text: $password)
                                .textContentType(.password)
                                .focused($isPasswordFocused)
                        } else {
                            SecureField("Enter password", text: $password)
                                .textContentType(.password)
                                .focused($isPasswordFocused)
                        }

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                }

                // Error message
                if let error = errorMessage {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                // Action buttons
                VStack(spacing: 12) {
                    Button {
                        attemptRevoke()
                    } label: {
                        HStack {
                            if isRevoking {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "xmark.circle")
                                Text("Revoke Connection")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(password.isEmpty ? Color.gray : Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(password.isEmpty || isRevoking)

                    Button("Cancel") {
                        onCancel()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Confirm Revocation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
            .onAppear {
                isPasswordFocused = true
            }
        }
    }

    private func attemptRevoke() {
        guard !password.isEmpty else { return }

        errorMessage = nil

        Task {
            await onAuthorize(password)
        }
    }
}

#if DEBUG
struct ServiceConnectionDetailView_Previews: PreviewProvider {
    static var previews: some View {
        Text("ServiceConnectionDetailView Preview")
    }
}
#endif
