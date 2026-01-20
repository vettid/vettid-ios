import SwiftUI
import UIKit

// MARK: - Notification Preferences Model

/// Notification preferences for a specific connection
struct ConnectionNotificationPreferences: Codable, Equatable {
    let connectionId: String
    var messagesEnabled: Bool = true
    var connectionRequestsEnabled: Bool = true
    var credentialRequestsEnabled: Bool = true
    var activityUpdatesEnabled: Bool = false
    var soundEnabled: Bool = true
    var vibrationEnabled: Bool = true
    var isMuted: Bool = false
    var mutedUntil: Date? = nil  // For temporary mute

    static func defaultPreferences(for connectionId: String) -> ConnectionNotificationPreferences {
        ConnectionNotificationPreferences(connectionId: connectionId)
    }
}

// MARK: - Notification Preferences Card

/// Card for configuring connection notification preferences
struct ConnectionNotificationPreferencesCard: View {
    @Binding var preferences: ConnectionNotificationPreferences
    @State private var showMuteOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.blue)
                Text("Notification Settings")
                    .font(.headline)
            }

            // Mute section
            MuteSection(
                isMuted: preferences.isMuted,
                mutedUntil: preferences.mutedUntil,
                showMuteOptions: $showMuteOptions,
                onMuteChange: { muted, until in
                    preferences.isMuted = muted
                    preferences.mutedUntil = until
                }
            )

            Divider()

            // Notification types
            VStack(alignment: .leading, spacing: 8) {
                Text("Notification Types")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.blue)

                NotificationToggle(
                    icon: "message.fill",
                    title: "Messages",
                    description: "New messages from this connection",
                    isEnabled: Binding(
                        get: { preferences.messagesEnabled && !preferences.isMuted },
                        set: { preferences.messagesEnabled = $0 }
                    ),
                    isDisabled: preferences.isMuted
                )

                NotificationToggle(
                    icon: "person.badge.plus",
                    title: "Connection Requests",
                    description: "Requests to share data",
                    isEnabled: Binding(
                        get: { preferences.connectionRequestsEnabled && !preferences.isMuted },
                        set: { preferences.connectionRequestsEnabled = $0 }
                    ),
                    isDisabled: preferences.isMuted
                )

                NotificationToggle(
                    icon: "key.fill",
                    title: "Credential Requests",
                    description: "Requests for your credentials",
                    isEnabled: Binding(
                        get: { preferences.credentialRequestsEnabled && !preferences.isMuted },
                        set: { preferences.credentialRequestsEnabled = $0 }
                    ),
                    isDisabled: preferences.isMuted
                )

                NotificationToggle(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Activity Updates",
                    description: "Profile changes and updates",
                    isEnabled: Binding(
                        get: { preferences.activityUpdatesEnabled && !preferences.isMuted },
                        set: { preferences.activityUpdatesEnabled = $0 }
                    ),
                    isDisabled: preferences.isMuted
                )
            }

            Divider()

            // Sound and vibration
            VStack(alignment: .leading, spacing: 8) {
                Text("Alert Style")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.blue)

                NotificationToggle(
                    icon: "speaker.wave.2.fill",
                    title: "Sound",
                    description: "Play notification sound",
                    isEnabled: Binding(
                        get: { preferences.soundEnabled && !preferences.isMuted },
                        set: { preferences.soundEnabled = $0 }
                    ),
                    isDisabled: preferences.isMuted
                )

                NotificationToggle(
                    icon: "iphone.radiowaves.left.and.right",
                    title: "Vibration",
                    description: "Vibrate on notification",
                    isEnabled: Binding(
                        get: { preferences.vibrationEnabled && !preferences.isMuted },
                        set: { preferences.vibrationEnabled = $0 }
                    ),
                    isDisabled: preferences.isMuted
                )
            }
        }
        .padding()
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
        .confirmationDialog("Mute Notifications", isPresented: $showMuteOptions) {
            Button("1 hour") {
                muteFor(hours: 1)
            }
            Button("8 hours") {
                muteFor(hours: 8)
            }
            Button("24 hours") {
                muteFor(hours: 24)
            }
            Button("1 week") {
                muteFor(hours: 24 * 7)
            }
            Button("Until I turn it back on") {
                preferences.isMuted = true
                preferences.mutedUntil = nil
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func muteFor(hours: Int) {
        preferences.isMuted = true
        preferences.mutedUntil = Calendar.current.date(byAdding: .hour, value: hours, to: Date())
    }
}

// MARK: - Mute Section

private struct MuteSection: View {
    let isMuted: Bool
    let mutedUntil: Date?
    @Binding var showMuteOptions: Bool
    let onMuteChange: (Bool, Date?) -> Void

    var body: some View {
        HStack {
            HStack(spacing: 12) {
                Image(systemName: isMuted ? "bell.slash.fill" : "bell.fill")
                    .foregroundStyle(isMuted ? .red : .blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isMuted ? "Muted" : "Notifications On")
                        .font(.subheadline)

                    if isMuted, let mutedUntil = mutedUntil {
                        Text("Until \(formatMuteTime(mutedUntil))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if isMuted {
                Button("Unmute") {
                    onMuteChange(false, nil)
                }
                .font(.subheadline)
            } else {
                Button("Mute") {
                    showMuteOptions = true
                }
                .font(.subheadline)
            }
        }
        .padding(12)
        .background(isMuted ? Color.red.opacity(0.1) : Color(UIColor.systemGray6))
        .cornerRadius(12)
    }

    private func formatMuteTime(_ date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        let hours = Int(diff / 3600)
        let days = hours / 24

        if days > 0 {
            return "\(days) day\(days > 1 ? "s" : "")"
        } else if hours > 0 {
            return "\(hours) hour\(hours > 1 ? "s" : "")"
        } else {
            return "soon"
        }
    }
}

// MARK: - Notification Toggle

private struct NotificationToggle: View {
    let icon: String
    let title: String
    let description: String
    @Binding var isEnabled: Bool
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .disabled(isDisabled)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Quick Mute Button

/// Quick mute button for list items
struct QuickMuteButton: View {
    let isMuted: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isMuted ? "bell.slash.fill" : "bell.fill")
                .foregroundStyle(isMuted ? .red : .secondary)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct NotificationPreferencesView_Previews: PreviewProvider {
    struct PreviewWrapper: View {
        @State private var preferences = ConnectionNotificationPreferences(connectionId: "preview")

        var body: some View {
            ScrollView {
                ConnectionNotificationPreferencesCard(preferences: $preferences)
                    .padding()
            }
            .background(Color(UIColor.systemGroupedBackground))
        }
    }

    static var previews: some View {
        PreviewWrapper()
    }
}
#endif
