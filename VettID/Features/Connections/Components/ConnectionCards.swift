import SwiftUI

// MARK: - Typed connection cards
//
// The Connections home renders a distinct card per connection type.
// Android shows a uniform list; this is a richer iOS design (approved
// by the team) where each type gets its own accent, icon, and primary
// capability. Shared chrome lives in `ConnectionCardChrome`; each card
// supplies its accent/icon/title/subtitle and an optional row of
// quick-action chips.

/// Shared card shell: a leading accent disc with an SF Symbol, a
/// title/subtitle stack, an optional trailing badge, and an optional
/// row of capability chips beneath.
struct ConnectionCardChrome<Trailing: View, Actions: View>: View {
    let accent: Color
    let icon: String
    let title: String
    let subtitle: String
    var typeBadge: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: 46, height: 46)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                        if let badge = typeBadge {
                            Text(badge.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(accent.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
                trailing()
            }

            actions()
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(accent.opacity(0.25), lineWidth: 1)
        )
    }
}

/// A small pill button used for per-type capabilities (message, call…).
struct CapabilityChip: View {
    let icon: String
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(label).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(tint.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - VettID system card

struct SystemConnectionCard: View {
    var subtitle: String = "Activity & audit trail"

    var body: some View {
        ConnectionCardChrome(
            accent: VettIDColor.systemAccent,
            icon: "shield.lefthalf.filled",
            title: "VettID",
            subtitle: subtitle,
            typeBadge: "System",
            trailing: { Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) },
            actions: { EmptyView() }
        )
    }
}

// MARK: - User / peer card

struct UserConnectionCard: View {
    let connection: Connection
    var onMessage: () -> Void = {}
    var onCall: () -> Void = {}

    var body: some View {
        ConnectionCardChrome(
            accent: VettIDColor.userAccent,
            icon: "person.fill",
            title: connection.peerDisplayName,
            subtitle: statusText,
            typeBadge: nil,
            trailing: {
                if connection.unreadCount > 0 {
                    Text("\(connection.unreadCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(VettIDColor.userAccent, in: Capsule())
                }
            },
            actions: {
                HStack(spacing: 8) {
                    CapabilityChip(icon: "message.fill", label: "Message", tint: VettIDColor.userAccent, action: onMessage)
                    CapabilityChip(icon: "phone.fill", label: "Call", tint: VettIDColor.userAccent, action: onCall)
                }
            }
        )
    }

    private var statusText: String {
        switch connection.status {
        case .pending: return "Pending"
        case .active: return "Connected"
        case .revoked: return "Revoked"
        }
    }
}

// MARK: - Desktop client card

struct DesktopConnectionCard: View {
    let device: ConnectedDevice
    var onManage: () -> Void = {}

    var body: some View {
        ConnectionCardChrome(
            accent: VettIDColor.desktopAccent,
            icon: device.platformIcon,
            title: displayName,
            subtitle: "\(platformLabel) · \(sessionText)",
            typeBadge: "Desktop",
            trailing: {
                Circle()
                    .fill(device.status == .active ? VettIDColor.statusConnected : VettIDColor.statusIdle)
                    .frame(width: 9, height: 9)
            },
            actions: {
                HStack(spacing: 8) {
                    CapabilityChip(icon: "rectangle.on.rectangle", label: "Sessions", tint: VettIDColor.desktopAccent, action: onManage)
                }
            }
        )
    }

    private var displayName: String {
        if let h = device.hostname, !h.isEmpty { return h }
        return device.deviceName
    }

    private var platformLabel: String {
        guard let p = device.platform, !p.isEmpty else { return "Device" }
        return p.capitalized
    }

    private var sessionText: String {
        device.sessionStatus?.displayName ?? "No active session"
    }
}

// MARK: - Agent card

struct AgentConnectionCard: View {
    let agent: AgentConnection
    var onChat: () -> Void = {}
    var onManage: () -> Void = {}

    var body: some View {
        ConnectionCardChrome(
            accent: VettIDColor.agentAccent,
            icon: "sparkles",
            title: agent.agentName,
            subtitle: scopeSummary,
            typeBadge: "Agent",
            trailing: {
                Circle()
                    .fill(agent.isActive ? VettIDColor.statusConnected : VettIDColor.statusIdle)
                    .frame(width: 9, height: 9)
            },
            actions: {
                HStack(spacing: 8) {
                    CapabilityChip(icon: "bubble.left.fill", label: "Chat", tint: VettIDColor.agentAccent, action: onChat)
                    CapabilityChip(icon: "slider.horizontal.3", label: "Scope", tint: VettIDColor.agentAccent, action: onManage)
                }
            }
        )
    }

    private var scopeSummary: String {
        if agent.scope.isEmpty { return agent.approvalModeDescription }
        return "\(agent.scope.count) scope\(agent.scope.count == 1 ? "" : "s") · \(agent.displayStatus)"
    }
}
