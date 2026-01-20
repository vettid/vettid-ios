import SwiftUI

/// View for managing per-service notification settings
struct ServiceNotificationSettingsView: View {
    @StateObject private var viewModel: ServiceNotificationSettingsViewModel
    @Environment(\.dismiss) private var dismiss

    init(connectionId: String, serviceName: String, serviceConnectionHandler: ServiceConnectionHandler) {
        self._viewModel = StateObject(wrappedValue: ServiceNotificationSettingsViewModel(
            connectionId: connectionId,
            serviceName: serviceName,
            serviceConnectionHandler: serviceConnectionHandler
        ))
    }

    var body: some View {
        NavigationView {
            Form {
                // Notification Level
                Section {
                    Picker("Notification Level", selection: $viewModel.settings.level) {
                        ForEach(NotificationLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                } header: {
                    Text("Notification Level")
                } footer: {
                    Text(levelDescription(viewModel.settings.level))
                }

                // Notification Types
                Section("Notification Types") {
                    Toggle("Data Requests", isOn: $viewModel.settings.dataRequestsEnabled)
                    Toggle("Auth Requests", isOn: $viewModel.settings.authRequestsEnabled)
                    Toggle("Messages", isOn: $viewModel.settings.messagesEnabled)
                    Toggle("Payment Requests", isOn: $viewModel.settings.paymentRequestsEnabled)
                }
                .disabled(viewModel.settings.level == .muted)

                // Quiet Hours Override
                Section {
                    Toggle("Bypass Quiet Hours", isOn: $viewModel.settings.bypassQuietHours)
                } header: {
                    Text("Quiet Hours")
                } footer: {
                    Text("When enabled, urgent notifications from this service will still be delivered during your quiet hours.")
                }

                // Preview
                Section("Preview") {
                    NotificationPreviewCard(
                        serviceName: viewModel.serviceName,
                        level: viewModel.settings.level
                    )
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await viewModel.saveSettings()
                            dismiss()
                        }
                    }
                    .disabled(viewModel.isSaving)
                }
            }
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.clearError() }
            } message: {
                if let error = viewModel.errorMessage {
                    Text(error)
                }
            }
            .task {
                await viewModel.loadSettings()
            }
        }
    }

    private func levelDescription(_ level: NotificationLevel) -> String {
        switch level {
        case .all: return "Receive all notifications from this service"
        case .important: return "Only receive critical notifications like security alerts and payment requests"
        case .muted: return "Don't receive any notifications from this service"
        }
    }
}

// MARK: - Notification Preview Card

struct NotificationPreviewCard: View {
    let serviceName: String
    let level: NotificationLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bell.fill")
                    .foregroundColor(level == .muted ? .gray : .blue)

                Text("Preview")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }

            // Simulated notification
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(String(serviceName.prefix(1)))
                            .foregroundColor(.white)
                            .fontWeight(.bold)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(serviceName)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("New data request awaiting your approval")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Text("now")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(UIColor.tertiarySystemBackground))
            .cornerRadius(12)
            .opacity(level == .muted ? 0.5 : 1.0)

            if level == .muted {
                Text("Notifications are muted")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if level == .important {
                Text("Only important notifications will be shown")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Notification Level Extension

extension NotificationLevel: CaseIterable {
    static var allCases: [NotificationLevel] {
        [.all, .important, .muted]
    }
}

// MARK: - Notification Settings ViewModel

@MainActor
final class ServiceNotificationSettingsViewModel: ObservableObject {
    @Published var settings: ServiceNotificationSettings
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    let serviceName: String
    private let connectionId: String
    private let serviceConnectionHandler: ServiceConnectionHandler

    init(connectionId: String, serviceName: String, serviceConnectionHandler: ServiceConnectionHandler) {
        self.connectionId = connectionId
        self.serviceName = serviceName
        self.serviceConnectionHandler = serviceConnectionHandler
        self.settings = ServiceNotificationSettings.defaultSettings(for: connectionId)
    }

    func loadSettings() async {
        do {
            settings = try await serviceConnectionHandler.getNotificationSettings(connectionId: connectionId)
        } catch {
            // Use defaults if loading fails
            settings = ServiceNotificationSettings.defaultSettings(for: connectionId)
        }
    }

    func saveSettings() async {
        isSaving = true

        do {
            _ = try await serviceConnectionHandler.updateNotificationSettings(settings)
        } catch {
            errorMessage = error.localizedDescription
        }

        isSaving = false
    }

    func clearError() {
        errorMessage = nil
    }
}

// MARK: - Compact Notification Settings Row

/// Compact row for notification settings in detail view
struct ServiceNotificationSettingsRow: View {
    let settings: ServiceNotificationSettings?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: notificationIcon)
                    .foregroundColor(notificationColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications")
                        .font(.subheadline)

                    Text(notificationStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var notificationIcon: String {
        guard let settings = settings else { return "bell" }
        switch settings.level {
        case .all: return "bell.fill"
        case .important: return "bell.badge"
        case .muted: return "bell.slash"
        }
    }

    private var notificationColor: Color {
        guard let settings = settings else { return .gray }
        switch settings.level {
        case .all: return .blue
        case .important: return .orange
        case .muted: return .gray
        }
    }

    private var notificationStatus: String {
        guard let settings = settings else { return "Loading..." }
        return settings.level.displayName
    }
}

#if DEBUG
struct ServiceNotificationSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Text("ServiceNotificationSettingsView Preview")
    }
}
#endif
