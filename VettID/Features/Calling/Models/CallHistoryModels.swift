import Foundation

// MARK: - Call History Entry

struct CallHistoryEntry: Identifiable {
    let callId: String
    let peerGuid: String
    let peerDisplayName: String?
    let callType: CallType
    let direction: CallDirection
    let endReason: CallEndReason
    let initiatedAt: Date
    let duration: TimeInterval?

    var id: String { callId }

    var formattedDuration: String? {
        guard let duration = duration, duration > 0 else { return nil }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var isMissed: Bool {
        endReason == .missed
    }
}

// MARK: - Call End Reason

enum CallEndReason: String, Codable {
    case missed
    case rejected
    case busy
    case timeout
    case failed
    case cancelled
    case completed
}
