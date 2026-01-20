import SwiftUI
import UIKit

// MARK: - Trust Event Models

/// Trust history event
struct TrustEvent: Identifiable {
    let id: String
    let type: TrustEventType
    let description: String
    let timestamp: Date
    let impact: TrustImpact
}

enum TrustEventType {
    case connectionEstablished
    case messageExchanged
    case credentialShared
    case credentialVerified
    case profileUpdated
    case mutualContactFound
    case longTermConnection
    case activityIncrease
    case inactivePeriod

    var icon: String {
        switch self {
        case .connectionEstablished: return "hand.wave.fill"
        case .messageExchanged: return "message.fill"
        case .credentialShared: return "square.and.arrow.up.fill"
        case .credentialVerified: return "checkmark.seal.fill"
        case .profileUpdated: return "pencil.circle.fill"
        case .mutualContactFound: return "person.2.fill"
        case .longTermConnection: return "clock.fill"
        case .activityIncrease: return "chart.line.uptrend.xyaxis"
        case .inactivePeriod: return "pause.circle.fill"
        }
    }
}

enum TrustImpact {
    case positive
    case neutral
    case negative

    var color: Color {
        switch self {
        case .positive: return Color(hex: "#4CAF50")
        case .neutral: return Color(hex: "#9E9E9E")
        case .negative: return Color(hex: "#F44336")
        }
    }
}

// MARK: - Trust Progress Card

/// Trust level progress card showing how trust builds over time
struct TrustProgressCard: View {
    let currentLevel: TrustLevel
    let nextLevel: TrustLevel?
    let progressToNext: Float  // 0.0 to 1.0
    let trustEvents: [TrustEvent]
    let onViewHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.blue)
                    Text("Trust Level")
                        .font(.headline)
                }

                Spacer()

                TrustBadge(trustLevel: currentLevel)
            }

            // Trust level visualization
            TrustLevelVisualization(
                currentLevel: currentLevel,
                progressToNext: progressToNext
            )

            // Next level info
            if let nextLevel = nextLevel {
                NextLevelInfo(
                    nextLevel: nextLevel,
                    progress: progressToNext
                )
            }

            Divider()

            // Recent trust events
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Activity")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.blue)

                ForEach(trustEvents.prefix(3)) { event in
                    TrustEventItem(event: event)
                }

                if trustEvents.count > 3 {
                    Button(action: onViewHistory) {
                        Text("View full history")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding()
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}

// MARK: - Trust Badge

struct TrustBadge: View {
    let trustLevel: TrustLevel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: trustLevelIcon)
                .font(.caption)
            Text(trustLevel.displayName)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(trustLevelColor.opacity(0.15))
        .foregroundStyle(trustLevelColor)
        .cornerRadius(8)
    }

    private var trustLevelColor: Color {
        Color(hex: trustLevel.color)
    }

    private var trustLevelIcon: String {
        switch trustLevel {
        case .new: return "star"
        case .established: return "star.leadinghalf.filled"
        case .trusted: return "star.fill"
        case .verified: return "checkmark.seal.fill"
        }
    }
}

// MARK: - Trust Level Visualization

private struct TrustLevelVisualization: View {
    let currentLevel: TrustLevel
    let progressToNext: Float

    private var levels: [(index: Int, level: TrustLevel)] {
        TrustLevel.allCases.enumerated().map { ($0.offset, $0.element) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(levels, id: \.level) { item in
                let isCurrentOrPast = item.level.ordinal <= currentLevel.ordinal
                let isCurrent = item.level == currentLevel

                // Level indicator
                VStack(spacing: 4) {
                    Circle()
                        .fill(isCurrentOrPast ? Color(hex: item.level.color) : Color(UIColor.systemGray4))
                        .frame(width: isCurrent ? 32 : 24, height: isCurrent ? 32 : 24)
                        .overlay {
                            if isCurrentOrPast {
                                Image(systemName: isCurrent ? "star.fill" : "checkmark")
                                    .foregroundStyle(.white)
                                    .font(isCurrent ? .body : .caption2)
                            }
                        }

                    Text(item.level.displayName)
                        .font(.caption2)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                }

                // Progress line between levels
                if item.index < TrustLevel.allCases.count - 1 {
                    GeometryReader { geometry in
                        let lineProgress: CGFloat = {
                            if item.index < currentLevel.ordinal {
                                return 1.0
                            } else if item.index == currentLevel.ordinal {
                                return CGFloat(progressToNext)
                            } else {
                                return 0.0
                            }
                        }()

                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color(UIColor.systemGray4))
                                .frame(height: 4)

                            Rectangle()
                                .fill(Color(hex: currentLevel.color))
                                .frame(width: geometry.size.width * lineProgress, height: 4)
                        }
                        .cornerRadius(2)
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 4)
                }
            }
        }
    }
}

// MARK: - Next Level Info

private struct NextLevelInfo: View {
    let nextLevel: TrustLevel
    let progress: Float

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Next: \(nextLevel.displayName)")
                    .font(.subheadline)
                Text(getNextLevelRequirements(nextLevel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(Int(progress * 100))%")
                .font(.headline)
                .foregroundStyle(.blue)
        }
        .padding(12)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }

    private func getNextLevelRequirements(_ level: TrustLevel) -> String {
        switch level {
        case .new: return "Connect to start"
        case .established: return "Exchange messages or share data"
        case .trusted: return "Verify credentials or find mutual connections"
        case .verified: return "Complete identity verification"
        }
    }
}

// MARK: - Trust Event Item

private struct TrustEventItem: View {
    let event: TrustEvent

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(event.impact.color)
                .frame(width: 8, height: 8)

            Image(systemName: event.type.icon)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(event.description)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Text(formatEventTime(event.timestamp))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func formatEventTime(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0

        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2..<7: return "\(days) days ago"
        case 7..<30: return "\(days / 7)w ago"
        default: return "\(days / 30)mo ago"
        }
    }
}

// MARK: - Trust Verification Section

/// Trust verification badge with explanation
struct TrustVerificationSection: View {
    let level: TrustLevel
    let verifications: [TrustVerification]
    let onVerify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trust Verification")
                    .font(.headline)
                Text("Verified actions that build trust")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(verifications) { verification in
                VerificationItem(verification: verification)
            }

            Button(action: onVerify) {
                Label("Verify More", systemImage: "checkmark.seal.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}

struct TrustVerification: Identifiable {
    let id: String
    let name: String
    let description: String
    let isCompleted: Bool
    let completedAt: Date?
}

private struct VerificationItem: View {
    let verification: TrustVerification

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(verification.isCompleted ? Color(hex: "#4CAF50").opacity(0.1) : Color(UIColor.systemGray5))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: verification.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(verification.isCompleted ? Color(hex: "#4CAF50") : .secondary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(verification.name)
                    .font(.subheadline)
                    .foregroundStyle(verification.isCompleted ? .primary : .secondary)
                Text(verification.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if verification.isCompleted, let completedAt = verification.completedAt {
                Text(formatTime(completedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatTime(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(days)d ago"
        }
    }
}

// MARK: - Mutual Connections Card

struct MutualConnectionsCard: View {
    let mutualCount: Int
    let mutualNames: [String]
    let onViewAll: () -> Void

    var body: some View {
        if mutualCount > 0 {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(mutualCount) mutual connection\(mutualCount > 1 ? "s" : "")")
                        .font(.subheadline)

                    let displayNames = mutualNames.prefix(3).joined(separator: ", ")
                    let suffix = mutualNames.count > 3 ? " +\(mutualNames.count - 3) more" : ""
                    Text(displayNames + suffix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("View", action: onViewAll)
                    .font(.subheadline)
            }
            .padding(12)
            .background(Color.purple.opacity(0.1))
            .cornerRadius(12)
        }
    }
}

// MARK: - Helper Extensions

extension TrustLevel {
    var ordinal: Int {
        switch self {
        case .new: return 0
        case .established: return 1
        case .trusted: return 2
        case .verified: return 3
        }
    }
}

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

// MARK: - Preview

#if DEBUG
struct TrustBuildingComponents_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: 16) {
                TrustProgressCard(
                    currentLevel: .established,
                    nextLevel: .trusted,
                    progressToNext: 0.65,
                    trustEvents: [
                        TrustEvent(
                            id: "1",
                            type: .messageExchanged,
                            description: "Exchanged 5 messages",
                            timestamp: Date(),
                            impact: .positive
                        ),
                        TrustEvent(
                            id: "2",
                            type: .credentialShared,
                            description: "Shared email credential",
                            timestamp: Date().addingTimeInterval(-86400),
                            impact: .positive
                        )
                    ],
                    onViewHistory: {}
                )

                MutualConnectionsCard(
                    mutualCount: 3,
                    mutualNames: ["Alice", "Bob", "Charlie"],
                    onViewAll: {}
                )
            }
            .padding()
        }
        .background(Color(UIColor.systemGroupedBackground))
    }
}
#endif
