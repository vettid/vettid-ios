import SwiftUI

// MARK: - Feed View

struct FeedView: View {
    @StateObject private var viewModel = FeedViewModel()
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            if isSearching {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search events...", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                        .onChange(of: viewModel.searchQuery) { newValue in
                            viewModel.searchEvents(query: newValue)
                        }
                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
                            viewModel.searchEvents(query: "")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Cancel") {
                        viewModel.searchQuery = ""
                        viewModel.searchEvents(query: "")
                        isSearching = false
                    }
                    .font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))
            }

            // Filter chips
            HStack {
                if !isSearching {
                    Button {
                        isSearching = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 16)
                    }
                }
                filterBar
            }

            // Content
            switch viewModel.state {
            case .loading:
                loadingView

            case .empty:
                emptyView

            case .loaded(let events):
                eventsList(events)

            case .error(let message):
                errorView(message)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        viewModel.markAllAsRead()
                    } label: {
                        Label("Mark All as Read", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await viewModel.loadEvents()
            viewModel.startPeriodicRefresh()
        }
        .onDisappear {
            viewModel.stopPeriodicRefresh()
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FeedViewModel.FeedFilter.allCases, id: \.rawValue) { filter in
                    FilterChip(
                        title: filter.rawValue,
                        isSelected: viewModel.filter == filter
                    ) {
                        viewModel.setFilter(filter)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
            Text("Loading feed...")
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "tray")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No Activity")
                .font(.title2)
                .fontWeight(.semibold)

            Text(emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    private var emptyMessage: String {
        switch viewModel.filter {
        case .all:
            return "Your feed is empty. New messages, connection requests, and activity will appear here."
        case .messages:
            return "No messages yet. Start a conversation with one of your connections."
        case .connections:
            return "No connection requests. Share your invitation to connect with others."
        case .auth:
            return "No authentication requests. Services you authorize will appear here."
        case .activity:
            return "No vault activity recorded yet."
        case .agents:
            return "No agent activity. Connected agents will appear here."
        case .devices:
            return "No device activity. Paired devices will appear here."
        }
    }

    // MARK: - Events List

    private func eventsList(_ events: [FeedEvent]) -> some View {
        List {
            ForEach(events) { event in
                EventCardView(
                    event: event,
                    isProcessing: viewModel.isProcessingAction,
                    onAcceptConnection: { requestId in
                        Task { await viewModel.acceptConnection(requestId: requestId) }
                    },
                    onDeclineConnection: { requestId in
                        Task { await viewModel.declineConnection(requestId: requestId) }
                    },
                    onApproveAuth: { requestId in
                        Task { await viewModel.approveAuth(requestId: requestId) }
                    },
                    onDenyAuth: { requestId in
                        Task { await viewModel.denyAuth(requestId: requestId) }
                    }
                )
                .onTapGesture {
                    handleEventTap(event)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        viewModel.archiveEvent(eventId: event.id)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .tint(.blue)

                    Button {
                        viewModel.pinEvent(eventId: event.id)
                    } label: {
                        Label("Pin", systemImage: "star")
                    }
                    .tint(.yellow)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        viewModel.deleteEvent(eventId: event.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.refresh()
        }
        .alert("Error", isPresented: .constant(viewModel.actionError != nil)) {
            Button("OK") {
                viewModel.actionError = nil
            }
        } message: {
            Text(viewModel.actionError ?? "")
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
    }

    // MARK: - Actions

    private func handleEventTap(_ event: FeedEvent) {
        viewModel.markAsRead(event)

        switch event {
        case .message(let e):
            // Navigate to conversation
            print("Navigate to conversation: \(e.connectionId)")
        case .connectionRequest(let e):
            // Navigate to connection request
            print("Navigate to connection request: \(e.id)")
        case .authRequest(let e):
            // Navigate to auth request
            print("Navigate to auth request: \(e.id)")
        case .vaultActivity:
            // No navigation needed
            break
        case .transferRequest(let e):
            // Navigate to conversation with payment request
            print("Navigate to transfer request from: \(e.connectionId)")
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue : Color(.systemGray6))
                .foregroundStyle(isSelected ? .white : .primary)
                .cornerRadius(20)
        }
    }
}

// MARK: - Event Card View

struct EventCardView: View {
    let event: FeedEvent
    let isProcessing: Bool
    let onAcceptConnection: (String) -> Void
    let onDeclineConnection: (String) -> Void
    let onApproveAuth: (String) -> Void
    let onDenyAuth: (String) -> Void

    /// Whether this event is pinned (high priority).
    /// Checks vault activity type or can be extended for other event types.
    private var isPinned: Bool {
        switch event {
        case .vaultActivity(let e):
            // Treat certain activity types as high priority
            switch e.activityType {
            case .vaultStopped: return true
            default: return false
            }
        case .authRequest(let e):
            return e.status == .pending
        default:
            return false
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Icon/Avatar
            eventIcon

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // Pin/priority indicator
                    if isPinned {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }

                    Text(eventTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Spacer()

                    Text(event.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(eventSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                eventBadge
                    .padding(.top, 4)
            }

            // Unread indicator
            if !event.isRead {
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Event Icon

    @ViewBuilder
    private var eventIcon: some View {
        switch event {
        case .message(let e):
            avatarView(name: e.senderName, avatarUrl: e.senderAvatarUrl)
        case .connectionRequest(let e):
            avatarView(name: e.requesterName, avatarUrl: e.requesterAvatarUrl)
        case .authRequest(let e):
            serviceIcon(name: e.serviceName, icon: e.serviceIcon)
        case .vaultActivity(let e):
            activityIcon(type: e.activityType)
        case .transferRequest(let e):
            avatarView(name: e.senderName, avatarUrl: nil)
        }
    }

    private func avatarView(name: String, avatarUrl: String?) -> some View {
        Group {
            if let url = avatarUrl, let imageUrl = URL(string: url) {
                AsyncImage(url: imageUrl) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    initialsView(name: name)
                }
            } else {
                initialsView(name: name)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }

    private func initialsView(name: String) -> some View {
        let initials = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
        return Circle()
            .fill(Color.blue.opacity(0.2))
            .overlay(
                Text(initials)
                    .font(.headline)
                    .foregroundStyle(.blue)
            )
    }

    private func serviceIcon(name: String, icon: String?) -> some View {
        ZStack {
            Circle()
                .fill(Color.purple.opacity(0.2))
                .frame(width: 44, height: 44)

            Image(systemName: icon ?? "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(.purple)
        }
    }

    private func activityIcon(type: VaultActivityEvent.VaultActivityType) -> some View {
        let color: Color = {
            switch type.color {
            case "green": return .green
            case "orange": return .orange
            case "blue": return .blue
            case "purple": return .purple
            case "teal": return .teal
            default: return .gray
            }
        }()

        return ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: 44, height: 44)

            Image(systemName: type.icon)
                .font(.title3)
                .foregroundStyle(color)
        }
    }

    // MARK: - Event Title

    private var eventTitle: String {
        switch event {
        case .message(let e):
            return e.senderName
        case .connectionRequest(let e):
            return e.requesterName
        case .authRequest(let e):
            return e.serviceName
        case .vaultActivity(let e):
            return e.activityType.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        case .transferRequest(let e):
            return e.senderName
        }
    }

    // MARK: - Event Subtitle

    private var eventSubtitle: String {
        switch event {
        case .message(let e):
            return e.preview
        case .connectionRequest(let e):
            switch e.status {
            case .pending:
                return "Wants to connect with you"
            case .accepted:
                return "Connection request accepted"
            case .declined:
                return "Connection request declined"
            }
        case .authRequest(let e):
            return e.actionType
        case .vaultActivity(let e):
            return e.description
        case .transferRequest(let e):
            return "Payment request for \(String(format: "%.8f", e.amountBtc)) BTC"
        }
    }

    // MARK: - Event Badge

    @ViewBuilder
    private var eventBadge: some View {
        switch event {
        case .connectionRequest(let e) where e.status == .pending:
            HStack(spacing: 8) {
                Button("Accept") {
                    onAcceptConnection(e.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isProcessing)

                Button("Decline") {
                    onDeclineConnection(e.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isProcessing)
            }
        case .authRequest(let e) where e.status == .pending:
            HStack(spacing: 8) {
                Button {
                    onApproveAuth(e.id)
                } label: {
                    Label("Approve", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isProcessing)

                Button {
                    onDenyAuth(e.id)
                } label: {
                    Label("Deny", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isProcessing)
            }
        case .authRequest(let e):
            statusBadge(status: e.status)
        default:
            EmptyView()
        }
    }

    private func statusBadge(status: AuthRequestEvent.AuthRequestStatus) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .pending: return ("Pending", .orange)
            case .approved: return ("Approved", .green)
            case .denied: return ("Denied", .red)
            case .expired: return ("Expired", .gray)
            }
        }()

        return Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .cornerRadius(4)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        FeedView()
    }
}
