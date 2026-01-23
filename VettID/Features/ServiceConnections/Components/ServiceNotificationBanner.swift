import SwiftUI

/// Banner notification for service events
/// Displays at the top of the screen with action buttons
struct ServiceNotificationBanner: View {
    let notification: ServiceNotification
    let onAction: (ServiceNotificationAction) -> Void
    let onDismiss: () -> Void

    @State private var isVisible = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Icon
                notificationIcon

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    Text(notification.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Text(notification.message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                // Dismiss button
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            // Action buttons
            if !notification.actions.isEmpty {
                Divider()

                HStack(spacing: 16) {
                    ForEach(notification.actions, id: \.type) { action in
                        Button(action.label) {
                            onAction(action)
                        }
                        .font(.subheadline)
                        .fontWeight(action.isPrimary ? .semibold : .regular)
                        .foregroundColor(action.isPrimary ? .accentColor : .secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.systemBackground))
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
        )
        .padding(.horizontal)
        .offset(y: isVisible ? 0 : -100)
        .opacity(isVisible ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isVisible)
        .onAppear {
            withAnimation {
                isVisible = true
            }
        }
    }

    private var notificationIcon: some View {
        ZStack {
            Circle()
                .fill(notification.type.color.opacity(0.15))
                .frame(width: 40, height: 40)

            Image(systemName: notification.type.icon)
                .font(.body)
                .foregroundColor(notification.type.color)
        }
    }
}

// MARK: - Notification Feed View

/// View showing a list of service notifications
struct ServiceNotificationFeedView: View {
    @StateObject private var viewModel = ServiceNotificationFeedViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading {
                loadingView
            } else if viewModel.notifications.isEmpty {
                emptyView
            } else {
                notificationList
            }
        }
        .navigationTitle("Notifications")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.notifications.isEmpty {
                    Button("Mark All Read") {
                        viewModel.markAllAsRead()
                    }
                }
            }
        }
        .task {
            await viewModel.loadNotifications()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    private var loadingView: some View {
        VStack {
            ProgressView()
            Text("Loading notifications...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Notifications")
                .font(.headline)

            Text("You're all caught up!")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var notificationList: some View {
        List {
            // Unread section
            let unread = viewModel.notifications.filter { !$0.isRead }
            if !unread.isEmpty {
                Section("Unread") {
                    ForEach(unread) { notification in
                        NotificationRow(notification: notification)
                            .onTapGesture {
                                viewModel.markAsRead(notification)
                            }
                    }
                }
            }

            // Earlier section
            let read = viewModel.notifications.filter { $0.isRead }
            if !read.isEmpty {
                Section("Earlier") {
                    ForEach(read) { notification in
                        NotificationRow(notification: notification)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Notification Row

struct NotificationRow: View {
    let notification: ServiceNotification

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(notification.type.color.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: notification.type.icon)
                    .foregroundColor(notification.type.color)
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(notification.serviceName)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(notification.timestamp.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Text(notification.title)
                    .font(.subheadline)
                    .fontWeight(notification.isRead ? .regular : .semibold)

                Text(notification.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            // Unread indicator
            if !notification.isRead {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Notification Toast

/// Compact toast notification that appears briefly
struct ServiceNotificationToast: View {
    let notification: ServiceNotification
    let onTap: () -> Void

    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notification.type.icon)
                .foregroundColor(notification.type.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.serviceName)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(notification.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        )
        .onTapGesture(perform: onTap)
        .offset(y: isVisible ? 0 : -50)
        .opacity(isVisible ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isVisible)
        .onAppear {
            withAnimation {
                isVisible = true
            }
        }
    }
}

// MARK: - Notification Types

/// Service notification model
struct ServiceNotification: Codable, Identifiable {
    let id: String
    let serviceId: String
    let serviceName: String
    let type: ServiceNotificationType
    let title: String
    let message: String
    var isRead: Bool
    let timestamp: Date
    let actions: [ServiceNotificationAction]
    let metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "notification_id"
        case serviceId = "service_id"
        case serviceName = "service_name"
        case type
        case title
        case message
        case isRead = "is_read"
        case timestamp
        case actions
        case metadata
    }
}

/// Notification types
enum ServiceNotificationType: String, Codable {
    case dataRequest = "data_request"
    case authRequest = "auth_request"
    case paymentRequest = "payment_request"
    case contractUpdate = "contract_update"
    case message
    case alert
    case info

    var icon: String {
        switch self {
        case .dataRequest: return "doc.text.fill"
        case .authRequest: return "person.badge.key.fill"
        case .paymentRequest: return "creditcard.fill"
        case .contractUpdate: return "doc.badge.arrow.up.fill"
        case .message: return "message.fill"
        case .alert: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .dataRequest: return .blue
        case .authRequest: return .green
        case .paymentRequest: return .orange
        case .contractUpdate: return .purple
        case .message: return .blue
        case .alert: return .red
        case .info: return .secondary
        }
    }
}

/// Notification action
struct ServiceNotificationAction: Codable {
    let type: String
    let label: String
    let isPrimary: Bool
    let metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case type
        case label
        case isPrimary = "is_primary"
        case metadata
    }
}

// MARK: - ViewModel

@MainActor
final class ServiceNotificationFeedViewModel: ObservableObject {
    @Published private(set) var notifications: [ServiceNotification] = []
    @Published private(set) var isLoading = false
    @Published private(set) var unreadCount = 0

    func loadNotifications() async {
        isLoading = true

        // Mock data for development
        #if DEBUG
        try? await Task.sleep(nanoseconds: 500_000_000)
        notifications = mockNotifications
        updateUnreadCount()
        #endif

        isLoading = false
    }

    func refresh() async {
        await loadNotifications()
    }

    func markAsRead(_ notification: ServiceNotification) {
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            notifications[index].isRead = true
            updateUnreadCount()
        }
    }

    func markAllAsRead() {
        for index in notifications.indices {
            notifications[index].isRead = true
        }
        updateUnreadCount()
    }

    private func updateUnreadCount() {
        unreadCount = notifications.filter { !$0.isRead }.count
    }

    #if DEBUG
    private var mockNotifications: [ServiceNotification] {
        [
            ServiceNotification(
                id: "notif-1",
                serviceId: "service-1",
                serviceName: "Example Bank",
                type: .authRequest,
                title: "Login Verification Required",
                message: "Approve login from new device in San Francisco, CA",
                isRead: false,
                timestamp: Date().addingTimeInterval(-300),
                actions: [
                    ServiceNotificationAction(type: "approve", label: "Approve", isPrimary: true, metadata: nil),
                    ServiceNotificationAction(type: "deny", label: "Deny", isPrimary: false, metadata: nil)
                ],
                metadata: nil
            ),
            ServiceNotification(
                id: "notif-2",
                serviceId: "service-2",
                serviceName: "HealthFirst",
                type: .dataRequest,
                title: "Data Access Request",
                message: "Requesting access to your email and phone number",
                isRead: false,
                timestamp: Date().addingTimeInterval(-3600),
                actions: [
                    ServiceNotificationAction(type: "review", label: "Review", isPrimary: true, metadata: nil)
                ],
                metadata: nil
            ),
            ServiceNotification(
                id: "notif-3",
                serviceId: "service-3",
                serviceName: "TechStore",
                type: .contractUpdate,
                title: "Contract Update Available",
                message: "New version of data agreement is ready for review",
                isRead: true,
                timestamp: Date().addingTimeInterval(-86400),
                actions: [
                    ServiceNotificationAction(type: "review", label: "Review Changes", isPrimary: true, metadata: nil)
                ],
                metadata: nil
            ),
            ServiceNotification(
                id: "notif-4",
                serviceId: "service-1",
                serviceName: "Example Bank",
                type: .message,
                title: "Secure Message",
                message: "You have a new secure message about your account",
                isRead: true,
                timestamp: Date().addingTimeInterval(-172800),
                actions: [],
                metadata: nil
            )
        ]
    }
    #endif
}

// MARK: - Previews

#if DEBUG
struct ServiceNotificationBanner_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            ServiceNotificationBanner(
                notification: ServiceNotification(
                    id: "test",
                    serviceId: "service-1",
                    serviceName: "Example Bank",
                    type: .authRequest,
                    title: "Login Verification",
                    message: "Approve login from new device",
                    isRead: false,
                    timestamp: Date(),
                    actions: [
                        ServiceNotificationAction(type: "approve", label: "Approve", isPrimary: true, metadata: nil),
                        ServiceNotificationAction(type: "deny", label: "Deny", isPrimary: false, metadata: nil)
                    ],
                    metadata: nil
                ),
                onAction: { _ in },
                onDismiss: {}
            )

            Spacer()
        }
        .padding(.top, 50)
    }
}

struct ServiceNotificationFeedView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ServiceNotificationFeedView()
        }
    }
}
#endif
