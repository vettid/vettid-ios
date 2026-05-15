import SwiftUI

/// Reusable card component for the connection-centric feed.
///
/// Renders peer avatar + name + last-activity glyph, an unread badge,
/// and a stack of tappable `PendingRow`s underneath the top row. The
/// pending rows are the only action affordance on a card — no more
/// inline accept/decline buttons.
struct ConnectionCard: View {
    let card: ConnectionCardData
    /// Tap handler for an individual pending row. Owned by the parent view
    /// so it can do real navigation; defaults to a no-op for previews.
    var onPendingRowTap: ((PendingRow) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            // Pending rows render below the top row, one per row,
            // each with its own glyph + tappable hit area.
            ForEach(card.pendingRows) { row in
                PendingRowView(row: row)
                    .contentShape(Rectangle())
                    .onTapGesture { onPendingRowTap?(row) }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Top row (avatar / name / glyph / unread badge)

    private var topRow: some View {
        HStack(spacing: 12) {
            avatarView
                .frame(width: 48, height: 48)
                .overlay(presenceRing)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(card.peerName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    if card.isAgent {
                        chipLabel("Agent", color: .purple)
                    } else if card.isDevice {
                        chipLabel("Device", color: .blue)
                    } else if card.isSystem {
                        chipLabel("VettID", color: .accentColor)
                    }

                    Spacer()

                    statusIndicator
                }

                if let preview = card.lastActivityPreview {
                    HStack(spacing: 6) {
                        if let direction = card.lastActivityDirection {
                            Image(systemName: direction == .sent
                                  ? "arrow.up.right" : "arrow.down.left")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let kind = card.lastActivityKind, let glyph = Self.kindGlyph(kind) {
                            Image(systemName: glyph)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(card.needsReview ? .orange : .secondary)
                        .lineLimit(1)
                }
            }

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
    }

    private func chipLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(3)
    }

    /// Green ring drawn around the avatar when the peer is online (a
    /// heartbeat landed within the presence-aggregator timeout). The
    /// VettID system card never carries presence.
    @ViewBuilder
    private var presenceRing: some View {
        if !card.isSystem,
           let lastSeen = card.presenceLastSeen,
           -lastSeen.timeIntervalSinceNow < 90 {
            Circle()
                .stroke(Color.green, lineWidth: 2)
                .padding(-1)
        }
    }

    private static func kindGlyph(_ kind: PendingRow.ActivityKind) -> String? {
        switch kind {
        case .message:    return "text.bubble"
        case .voiceCall:  return "phone.fill"
        case .videoCall:  return "video.fill"
        case .transfer:   return "bitcoinsign.circle"
        case .other:      return nil
        }
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
        if card.hasOutstandingInvitation {
            return "Invitation sent — tap to manage"
        }
        switch card.connectionStatus {
        case "pending":
            return card.direction == "outbound" ? "Waiting for response" : "Connection request"
        case "active":
            return "Connected"
        case "revoked":
            return "Connection revoked"
        case "rejected", "declined":
            return "Connection declined"
        case "expired":
            return "Invitation expired"
        default:
            return card.connectionStatus.capitalized
        }
    }
}

// MARK: - PendingRowView

/// A single tappable notification row rendered inside a connection card.
/// Each row carries a glyph + label and represents one action the user
/// can take (review, reply, view missed call, vote, read guide, …).
struct PendingRowView: View {
    let row: PendingRow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: glyph)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)

            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 60)        // Indent under the avatar.
        .padding(.trailing, 4)
        .padding(.vertical, 4)
    }

    private var glyph: String {
        switch row {
        case .unreadMessages:        return "text.bubble.fill"
        case .missedCall(_, let k, _):
            return k == .video ? "video.slash.fill" : "phone.down.fill"
        case .pendingReview:         return "person.crop.circle.badge.questionmark"
        case .pendingMigration:      return "arrow.triangle.2.circlepath"
        case .guideUnread:           return "book.fill"
        case .proposalUnvoted:       return "checkmark.bubble"
        case .peerLocationShare:     return "location.fill"
        case .incomingGrantRequest:  return "lock.shield"
        case .lastActivity(_, _, let k, _):
            switch k {
            case .message:    return "text.bubble"
            case .voiceCall:  return "phone"
            case .videoCall:  return "video"
            case .transfer:   return "bitcoinsign.circle"
            case .other:      return "circle.dotted"
            }
        }
    }

    private var tint: Color {
        switch row {
        case .pendingReview, .pendingMigration, .incomingGrantRequest: return .orange
        case .missedCall:                                              return .red
        case .unreadMessages, .peerLocationShare:                      return .accentColor
        case .guideUnread, .proposalUnvoted:                           return .purple
        case .lastActivity:                                            return .secondary
        }
    }

    private var label: String {
        switch row {
        case .unreadMessages(let count, let preview):
            if let p = preview, !p.isEmpty { return p }
            return count == 1 ? "1 new message" : "\(count) new messages"
        case .missedCall(let count, let kind, _):
            let suffix = kind == .video ? "video call" : "call"
            return count == 1 ? "Missed \(suffix)" : "\(count) missed \(suffix)s"
        case .pendingReview:
            return "Wants to connect — tap to review"
        case .pendingMigration(let version):
            return version.map { "Update available — \($0)" } ?? "Update available"
        case .guideUnread(_, let title):
            return title
        case .proposalUnvoted(_, let title):
            return "Vote: \(title)"
        case .peerLocationShare(_, let at):
            return "Shared location \(Self.relative(at))"
        case .incomingGrantRequest(_, let kind):
            switch kind {
            case .data:           return "Wants to access your data"
            case .criticalUse:    return "Wants to use a critical secret"
            case .verifyIdentity: return "Wants to verify your identity"
            }
        case .lastActivity(let text, _, _, _):
            return text
        }
    }

    private static func relative(_ date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
