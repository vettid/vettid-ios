import SwiftUI

/// Reusable card component for the connection-centric feed.
/// Shows peer avatar, name, last activity preview, unread badge, and status.
struct ConnectionCard: View {
    let card: ConnectionCardData

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            avatarView
                .frame(width: 48, height: 48)

            // Content
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(card.peerName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    if card.isAgent {
                        Text("Agent")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15))
                            .foregroundColor(.purple)
                            .cornerRadius(3)
                    } else if card.isDevice {
                        Text("Device")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(3)
                    }

                    Spacer()

                    statusIndicator
                }

                if let preview = card.lastActivityPreview {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundColor(card.needsReview ? .orange : .secondary)
                        .lineLimit(1)
                }
            }

            // Unread badge
            if card.unreadCount > 0 {
                Text("\(card.unreadCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatarView: some View {
        if let photoBase64 = card.peerPhotoBase64,
           let data = Data(base64Encoded: photoBase64),
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .overlay(
                    Text(String(card.peerName.prefix(1)).uppercased())
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.accentColor)
                )
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch card.connectionStatus {
        case "active": return .green
        case "pending": return .orange
        case "revoked", "rejected": return .red
        default: return .gray
        }
    }

    private var statusText: String {
        if card.needsReview {
            return "Wants to connect — tap to review"
        }
        switch card.connectionStatus {
        case "pending":
            return card.direction == "outbound" ? "Waiting for response" : "Connection request"
        case "active":
            return "Connected"
        case "revoked":
            return "Connection revoked"
        case "rejected":
            return "Connection declined"
        default:
            return card.connectionStatus.capitalized
        }
    }
}
