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

// MARK: - Connection Health Status

enum ConnectionHealthStatus: String, Codable {
    case excellent
    case good
    case fair
    case poor
    case unknown

    var displayName: String {
        switch self {
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Poor"
        case .unknown: return "Unknown"
        }
    }

    var icon: String {
        switch self {
        case .excellent: return "checkmark.circle.fill"
        case .good: return "checkmark.circle"
        case .fair: return "exclamationmark.circle"
        case .poor: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .excellent: return Color(hex: "#4CAF50")
        case .good: return Color(hex: "#8BC34A")
        case .fair: return Color(hex: "#FF9800")
        case .poor: return Color(hex: "#F44336")
        case .unknown: return Color(hex: "#9E9E9E")
        }
    }
}

// MARK: - Connection Health Metrics

struct ConnectionHealthMetrics {
    let responseTime: TimeInterval?     // Average response time in seconds
    let messageDeliveryRate: Double?    // 0.0 to 1.0
    let lastActiveAt: Date?
    let encryptionStrength: String?     // e.g., "256-bit AES"
    let keyAge: TimeInterval?           // Age of encryption keys in seconds

    var overallStatus: ConnectionHealthStatus {
        // Calculate overall health based on metrics
        guard let responseTime = responseTime,
              let deliveryRate = messageDeliveryRate else {
            return .unknown
        }

        if responseTime < 0.5 && deliveryRate > 0.99 {
            return .excellent
        } else if responseTime < 1.0 && deliveryRate > 0.95 {
            return .good
        } else if responseTime < 2.0 && deliveryRate > 0.90 {
            return .fair
        } else {
            return .poor
        }
    }

    static let unknown = ConnectionHealthMetrics(
        responseTime: nil,
        messageDeliveryRate: nil,
        lastActiveAt: nil,
        encryptionStrength: nil,
        keyAge: nil
    )
}

// MARK: - Connection Health Card

/// Card showing connection health metrics
struct ConnectionHealthCard: View {
    let metrics: ConnectionHealthMetrics
    let onRefreshKeys: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with overall status
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(.blue)
                    Text("Connection Health")
                        .font(.headline)
                }

                Spacer()

                HealthStatusBadge(status: metrics.overallStatus)
            }

            Divider()

            // Metrics grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                // Response time
                MetricItem(
                    icon: "clock",
                    label: "Response Time",
                    value: formatResponseTime(metrics.responseTime),
                    status: responseTimeStatus
                )

                // Delivery rate
                MetricItem(
                    icon: "checkmark.message",
                    label: "Delivery Rate",
                    value: formatDeliveryRate(metrics.messageDeliveryRate),
                    status: deliveryRateStatus
                )

                // Last active
                MetricItem(
                    icon: "person.wave.2",
                    label: "Last Active",
                    value: formatLastActive(metrics.lastActiveAt),
                    status: lastActiveStatus
                )

                // Encryption
                MetricItem(
                    icon: "lock.shield",
                    label: "Encryption",
                    value: metrics.encryptionStrength ?? "Unknown",
                    status: .excellent
                )
            }

            // Key rotation warning
            if let keyAge = metrics.keyAge, keyAge > 7 * 24 * 3600 {  // > 7 days
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)

                    Text("Keys are \(Int(keyAge / 86400)) days old. Consider refreshing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let onRefreshKeys = onRefreshKeys {
                        Button("Refresh", action: onRefreshKeys)
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    private var responseTimeStatus: ConnectionHealthStatus {
        guard let time = metrics.responseTime else { return .unknown }
        if time < 0.5 { return .excellent }
        if time < 1.0 { return .good }
        if time < 2.0 { return .fair }
        return .poor
    }

    private var deliveryRateStatus: ConnectionHealthStatus {
        guard let rate = metrics.messageDeliveryRate else { return .unknown }
        if rate > 0.99 { return .excellent }
        if rate > 0.95 { return .good }
        if rate > 0.90 { return .fair }
        return .poor
    }

    private var lastActiveStatus: ConnectionHealthStatus {
        guard let lastActive = metrics.lastActiveAt else { return .unknown }
        let hoursSince = Date().timeIntervalSince(lastActive) / 3600
        if hoursSince < 24 { return .excellent }
        if hoursSince < 72 { return .good }
        if hoursSince < 168 { return .fair }
        return .poor
    }

    private func formatResponseTime(_ time: TimeInterval?) -> String {
        guard let time = time else { return "N/A" }
        if time < 1 {
            return "\(Int(time * 1000))ms"
        }
        return String(format: "%.1fs", time)
    }

    private func formatDeliveryRate(_ rate: Double?) -> String {
        guard let rate = rate else { return "N/A" }
        return "\(Int(rate * 100))%"
    }

    private func formatLastActive(_ date: Date?) -> String {
        guard let date = date else { return "Never" }
        let hours = Int(Date().timeIntervalSince(date) / 3600)
        if hours < 1 { return "Just now" }
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

// MARK: - Health Status Badge

struct HealthStatusBadge: View {
    let status: ConnectionHealthStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.caption)
            Text(status.displayName)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(status.color.opacity(0.15))
        .foregroundStyle(status.color)
        .cornerRadius(8)
    }
}

// MARK: - Metric Item

private struct MetricItem: View {
    let icon: String
    let label: String
    let value: String
    let status: ConnectionHealthStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(status.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Spacer()
        }
        .padding(8)
        .background(Color(UIColor.systemGray6))
        .cornerRadius(8)
    }
}

// MARK: - Compact Health Indicator

/// Compact health indicator for list items
struct CompactHealthIndicator: View {
    let status: ConnectionHealthStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
    }
}

// MARK: - Preview

#if DEBUG
struct ConnectionHealthView_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: 16) {
                ConnectionHealthCard(
                    metrics: ConnectionHealthMetrics(
                        responseTime: 0.3,
                        messageDeliveryRate: 0.98,
                        lastActiveAt: Date().addingTimeInterval(-3600),
                        encryptionStrength: "256-bit ChaCha20",
                        keyAge: 10 * 24 * 3600
                    ),
                    onRefreshKeys: {}
                )

                ConnectionHealthCard(
                    metrics: .unknown,
                    onRefreshKeys: nil
                )
            }
            .padding()
        }
        .background(Color(UIColor.systemGroupedBackground))
    }
}
#endif
