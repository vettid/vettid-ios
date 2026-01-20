import SwiftUI
import UIKit

// MARK: - Color Extension (Hex Support)

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Invitation Status

/// Status of an invitation
enum InvitationStatus: String, Codable {
    case pending      // Waiting to be scanned
    case viewed       // Scanned but not accepted
    case accepted     // Successfully connected
    case expired      // Time ran out
    case revoked      // Manually cancelled

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .viewed: return "Viewed"
        case .accepted: return "Accepted"
        case .expired: return "Expired"
        case .revoked: return "Revoked"
        }
    }

    var color: Color {
        switch self {
        case .pending: return Color(hex: "#FF9800")
        case .viewed: return Color(hex: "#2196F3")
        case .accepted: return Color(hex: "#4CAF50")
        case .expired: return Color(hex: "#9E9E9E")
        case .revoked: return Color(hex: "#F44336")
        }
    }
}

/// Direction of invitation
enum InvitationDirection: String, Codable {
    case outbound     // Created by user
    case inbound      // Received from others
}

/// Data class for an invitation
struct TrackedInvitation: Identifiable, Codable {
    let id: String
    let direction: InvitationDirection
    let status: InvitationStatus
    let peerName: String?           // Known after connection or if provided
    let createdAt: Date
    let expiresAt: Date
    let acceptedAt: Date?
    let connectionId: String?       // Set after successful connection

    init(
        id: String,
        direction: InvitationDirection,
        status: InvitationStatus,
        peerName: String? = nil,
        createdAt: Date,
        expiresAt: Date,
        acceptedAt: Date? = nil,
        connectionId: String? = nil
    ) {
        self.id = id
        self.direction = direction
        self.status = status
        self.peerName = peerName
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.acceptedAt = acceptedAt
        self.connectionId = connectionId
    }
}

// MARK: - Pending Invitations Summary Card

/// Card showing pending invitations summary
struct PendingInvitationsSummaryCard: View {
    let outboundCount: Int
    let inboundCount: Int
    let onViewAll: () -> Void

    var body: some View {
        if outboundCount > 0 || inboundCount > 0 {
            HStack {
                HStack(spacing: 12) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pending Invitations")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        let text = buildSummaryText()
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("View", action: onViewAll)
                    .font(.subheadline)
            }
            .padding()
            .background(Color.orange.opacity(0.1))
            .cornerRadius(12)
        }
    }

    private func buildSummaryText() -> String {
        var parts: [String] = []
        if outboundCount > 0 {
            parts.append("\(outboundCount) sent")
        }
        if inboundCount > 0 {
            parts.append("\(inboundCount) received")
        }
        return parts.joined(separator: " \u{2022} ")
    }
}

// MARK: - Invitation Tracking List

/// Detailed invitation tracking list
struct InvitationTrackingList: View {
    let invitations: [TrackedInvitation]
    let onInvitationClick: (String) -> Void
    let onRevokeInvitation: (String) -> Void

    var body: some View {
        List {
            // Group by status
            let grouped = Dictionary(grouping: invitations, by: { $0.status })

            // Pending first
            if let pending = grouped[.pending], !pending.isEmpty {
                Section {
                    ForEach(pending) { invitation in
                        InvitationTrackingItem(
                            invitation: invitation,
                            onClick: { onInvitationClick(invitation.id) },
                            onRevoke: { onRevokeInvitation(invitation.id) }
                        )
                    }
                } header: {
                    SectionHeader(title: "Pending", count: pending.count, color: Color(hex: "#FF9800"))
                }
            }

            // Accepted
            if let accepted = grouped[.accepted], !accepted.isEmpty {
                Section {
                    ForEach(accepted) { invitation in
                        InvitationTrackingItem(
                            invitation: invitation,
                            onClick: { onInvitationClick(invitation.id) },
                            onRevoke: nil
                        )
                    }
                } header: {
                    SectionHeader(title: "Accepted", count: accepted.count, color: Color(hex: "#4CAF50"))
                }
            }

            // Expired/Revoked (History)
            let inactive = (grouped[.expired] ?? []) + (grouped[.revoked] ?? [])
            if !inactive.isEmpty {
                Section {
                    ForEach(inactive) { invitation in
                        InvitationTrackingItem(
                            invitation: invitation,
                            onClick: { onInvitationClick(invitation.id) },
                            onRevoke: nil
                        )
                    }
                } header: {
                    SectionHeader(title: "History", count: inactive.count, color: Color(hex: "#9E9E9E"))
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)

            Text("\(title) (\(count))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Invitation Tracking Item

private struct InvitationTrackingItem: View {
    let invitation: TrackedInvitation
    let onClick: () -> Void
    let onRevoke: (() -> Void)?

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 12) {
                // Direction icon
                Circle()
                    .fill(invitation.status.color.opacity(0.1))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: invitation.direction == .outbound ? "arrow.up.right" : "arrow.down.left")
                            .font(.body)
                            .foregroundStyle(invitation.status.color)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(invitation.peerName ?? "Pending connection")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        InvitationStatusChip(status: invitation.status)
                    }

                    Text(getInvitationSubtext())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if invitation.status == .pending, let onRevoke = onRevoke {
                    Button(action: onRevoke) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func getInvitationSubtext() -> String {
        let direction = invitation.direction == .outbound ? "Sent" : "Received"
        let time = formatRelativeTime(invitation.createdAt)

        switch invitation.status {
        case .pending:
            let remaining = formatTimeRemaining(invitation.expiresAt)
            return "\(direction) \(time) \u{2022} Expires in \(remaining)"
        case .viewed:
            return "\(direction) \(time) \u{2022} Awaiting response"
        case .accepted:
            let acceptedTime = invitation.acceptedAt.map { formatRelativeTime($0) } ?? "recently"
            return "Connected \(acceptedTime)"
        case .expired:
            return "\(direction) \(time) \u{2022} Expired"
        case .revoked:
            return "\(direction) \(time) \u{2022} Cancelled"
        }
    }

    private func formatRelativeTime(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        let hours = minutes / 60
        let days = hours / 24

        switch minutes {
        case ..<1: return "just now"
        case 1..<60: return "\(minutes) min ago"
        case 60..<1440: return "\(hours) hr ago"
        case 1440..<10080: return "\(days) days ago"
        default: return "\(days / 7) weeks ago"
        }
    }

    private func formatTimeRemaining(_ expiresAt: Date) -> String {
        let seconds = Int(expiresAt.timeIntervalSince(Date()))
        let minutes = seconds / 60

        switch seconds {
        case ..<1: return "expired"
        case 1..<60: return "\(seconds)s"
        case 60..<3600: return "\(minutes)m"
        default: return "\(minutes / 60)h \(minutes % 60)m"
        }
    }
}

// MARK: - Invitation Status Chip

private struct InvitationStatusChip: View {
    let status: InvitationStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(status.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status.color.opacity(0.15))
            .cornerRadius(4)
    }
}

// MARK: - Invitation Detail Card

/// Invitation detail card
struct InvitationDetailCard: View {
    let invitation: TrackedInvitation
    let onRevoke: (() -> Void)?
    let onResend: (() -> Void)?
    let onViewConnection: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Invitation Details")
                    .font(.headline)
                Spacer()
                InvitationStatusChip(status: invitation.status)
            }

            Divider()

            // Details
            DetailRow(label: "Direction", value: invitation.direction == .outbound ? "Sent" : "Received")
            DetailRow(label: "Created", value: formatRelativeTime(invitation.createdAt))

            if invitation.status == .pending {
                let expiresColor: Color = {
                    let minutes = Int(invitation.expiresAt.timeIntervalSince(Date()) / 60)
                    return minutes < 5 ? .red : .primary
                }()
                DetailRow(
                    label: "Expires",
                    value: formatTimeRemaining(invitation.expiresAt),
                    valueColor: expiresColor
                )
            }

            if let acceptedAt = invitation.acceptedAt {
                DetailRow(label: "Accepted", value: formatRelativeTime(acceptedAt))
            }

            if let peerName = invitation.peerName {
                DetailRow(label: "Connected to", value: peerName)
            }

            // Actions
            HStack(spacing: 8) {
                if invitation.status == .pending, let onRevoke = onRevoke {
                    Button("Revoke", role: .destructive, action: onRevoke)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }

                if invitation.status == .expired, let onResend = onResend {
                    Button("Resend", action: onResend)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }

                if invitation.status == .accepted && invitation.connectionId != nil, let onViewConnection = onViewConnection {
                    Button("View Connection", action: onViewConnection)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding()
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    private func formatRelativeTime(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        let hours = minutes / 60
        let days = hours / 24

        switch minutes {
        case ..<1: return "just now"
        case 1..<60: return "\(minutes) min ago"
        case 60..<1440: return "\(hours) hr ago"
        default: return "\(days) days ago"
        }
    }

    private func formatTimeRemaining(_ expiresAt: Date) -> String {
        let seconds = Int(expiresAt.timeIntervalSince(Date()))
        let minutes = seconds / 60

        switch seconds {
        case ..<1: return "expired"
        case 1..<60: return "\(seconds)s"
        case 60..<3600: return "\(minutes)m"
        default: return "\(minutes / 60)h \(minutes % 60)m"
        }
    }
}

// MARK: - Detail Row

private struct DetailRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(valueColor)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

#if DEBUG
struct InvitationTrackingView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            PendingInvitationsSummaryCard(
                outboundCount: 2,
                inboundCount: 1,
                onViewAll: {}
            )

            InvitationDetailCard(
                invitation: TrackedInvitation(
                    id: "1",
                    direction: .outbound,
                    status: .pending,
                    peerName: nil,
                    createdAt: Date().addingTimeInterval(-3600),
                    expiresAt: Date().addingTimeInterval(3600)
                ),
                onRevoke: {},
                onResend: nil,
                onViewConnection: nil
            )
        }
        .padding()
        .background(Color(UIColor.systemGroupedBackground))
    }
}
#endif
