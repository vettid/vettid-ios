import SwiftUI
import UIKit

// MARK: - Connection Preview Data

/// Preview data shown before accepting an invitation
struct ConnectionPreviewData {
    let peerDisplayName: String
    let peerAvatarUrl: String?
    let peerBio: String?
    let peerLocation: String?
    let mutualConnectionCount: Int
    let mutualConnectionNames: [String]
    let invitedAt: Date
    let expiresAt: Date
    let trustIndicators: [TrustIndicator]
}

/// Trust indicator for preview
struct TrustIndicator: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let isPositive: Bool
}

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

// MARK: - Connection Preview Card

/// Card showing profile preview before accepting a connection
struct ConnectionPreviewCard: View {
    let preview: ConnectionPreviewData
    let onAccept: () -> Void
    let onDecline: () -> Void
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 20) {
            // Avatar and name
            VStack(spacing: 12) {
                // Avatar
                AsyncImage(url: URL(string: preview.peerAvatarUrl ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
                .frame(width: 80, height: 80)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(Color.blue.opacity(0.3), lineWidth: 3)
                }

                // Name
                Text(preview.peerDisplayName)
                    .font(.title2)
                    .fontWeight(.bold)

                // Bio
                if let bio = preview.peerBio, !bio.isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                // Location
                if let location = preview.peerLocation, !location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .font(.caption)
                        Text(location)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Trust indicators
            if !preview.trustIndicators.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trust Indicators")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    ForEach(preview.trustIndicators) { indicator in
                        HStack(spacing: 8) {
                            Image(systemName: indicator.icon)
                                .font(.caption)
                                .foregroundStyle(indicator.isPositive ? .green : .orange)

                            Text(indicator.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Mutual connections
            if preview.mutualConnectionCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(.purple)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(preview.mutualConnectionCount) mutual connection\(preview.mutualConnectionCount > 1 ? "s" : "")")
                            .font(.caption)
                            .fontWeight(.medium)

                        if !preview.mutualConnectionNames.isEmpty {
                            Text(preview.mutualConnectionNames.prefix(3).joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding(12)
                .background(Color.purple.opacity(0.1))
                .cornerRadius(8)
            }

            // Expiration warning
            let timeRemaining = preview.expiresAt.timeIntervalSince(Date())
            if timeRemaining < 300 { // Less than 5 minutes
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Text("Expires in \(formatTimeRemaining(timeRemaining))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button(action: onDecline) {
                    Label("Decline", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isLoading)

                Button(action: onAccept) {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Accept", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            }

            // Security note
            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(.caption2)
                Text("End-to-end encrypted connection")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
    }

    private func formatTimeRemaining(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let secs = Int(seconds) % 60

        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }
}

// MARK: - Compact Preview Row

/// Compact preview for inline display
struct CompactConnectionPreview: View {
    let preview: ConnectionPreviewData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Avatar
                AsyncImage(url: URL(string: preview.peerAvatarUrl ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
                .frame(width: 50, height: 50)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.peerDisplayName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if preview.mutualConnectionCount > 0 {
                        Text("\(preview.mutualConnectionCount) mutual")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(UIColor.systemGray6))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview Loading State

struct ConnectionPreviewLoading: View {
    var body: some View {
        VStack(spacing: 20) {
            // Avatar placeholder
            Circle()
                .fill(Color(UIColor.systemGray5))
                .frame(width: 80, height: 80)

            // Text placeholders
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(UIColor.systemGray5))
                    .frame(width: 150, height: 20)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(UIColor.systemGray5))
                    .frame(width: 200, height: 14)
            }

            Divider()

            // Button placeholders
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(UIColor.systemGray5))
                    .frame(height: 44)

                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(UIColor.systemGray5))
                    .frame(height: 44)
            }
        }
        .padding(20)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(16)
        .redacted(reason: .placeholder)
        .shimmering()
    }
}

// MARK: - Shimmer Effect

extension View {
    func shimmering() -> some View {
        self.modifier(ShimmerModifier())
    }
}

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        gradient: Gradient(colors: [
                            .clear,
                            Color.white.opacity(0.4),
                            .clear
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 2)
                    .offset(x: -geometry.size.width + (phase * geometry.size.width * 3))
                }
            )
            .mask(content)
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - Preview

#if DEBUG
struct ConnectionPreviewCard_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            ConnectionPreviewCard(
                preview: ConnectionPreviewData(
                    peerDisplayName: "Alice Johnson",
                    peerAvatarUrl: nil,
                    peerBio: "Software engineer passionate about privacy",
                    peerLocation: "San Francisco, CA",
                    mutualConnectionCount: 3,
                    mutualConnectionNames: ["Bob", "Charlie", "Diana"],
                    invitedAt: Date().addingTimeInterval(-3600),
                    expiresAt: Date().addingTimeInterval(180),
                    trustIndicators: [
                        TrustIndicator(icon: "checkmark.seal", label: "Verified email", isPositive: true),
                        TrustIndicator(icon: "person.2", label: "3 mutual connections", isPositive: true)
                    ]
                ),
                onAccept: {},
                onDecline: {},
                isLoading: false
            )

            ConnectionPreviewLoading()
        }
        .padding()
        .background(Color(UIColor.systemGroupedBackground))
    }
}
#endif
