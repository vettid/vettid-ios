import Foundation
import VettIDCrypto
import VettIDVault

// The calls of a conversation, from the vault's `call.list` (vettid-android `CallAccess.kt` and `CallsController.entry`).

/// Whether a conversation can show a call button, and why not. (Android's `NOT_IN_BUILD` is not here: a build without calls does
/// not link this package.)
public enum CallAvailability: Equatable, Sendable {
    /// The vault has not been asked yet (it is locked, or was just opened): no button.
    case unknown
    /// The vault's release has no calls ("Calls are not available for your vault yet"): no button.
    case notInVault
    /// The button calls.
    case ready
    /// A call is going on: the button is disabled.
    case inCall
}

/// How a past call ended, as the conversation shows it. A call answered on another of the member's devices, and one still going
/// on, have no row (``CallHistoryRows/outcome(_:now:)`` is nil for them).
public enum CallOutcome: Equatable, Sendable {
    case talked, declined, declinedHere, busy, notAnswered, missed, failed
}

/// One call of the vault's history (it keeps the latest 200; no content, no keys).
public struct CallHistoryEntry: Equatable, Sendable {
    public let callId: String
    public let connectionId: String
    public let outgoing: Bool
    public let outcome: CallOutcome
    public let startedAt: Date
    /// How long the call was answered for; nil if it never was.
    public let duration: Duration?
}

/// A conversation's calls: [entries], newest first, and [someNotShown] when the vault's list had entries that did not read: the
/// list then says "Some calls couldn't be shown.".
public struct CallHistory: Equatable, Sendable {
    public var entries: [CallHistoryEntry]
    public var someNotShown: Bool

    public init(entries: [CallHistoryEntry] = [], someNotShown: Bool = false) {
        self.entries = entries
        self.someNotShown = someNotShown
    }
}

/// The rules that turn `call.list` records into rows.
enum CallHistoryRows {
    /// A `ringing` record older than this is not ringing any more. Two minutes: an offer lives 45 s (90 s is the most a vault
    /// accepts), and the record's time is the vault's while "now" is this phone's, so the rest is margin for their clocks and
    /// for a hang-up on its way. Erring long only shows a finished call as going on for a moment; erring short would end a call
    /// that is still ringing.
    static let ringStale: Duration = .seconds(120)
    static let ringStaleSeconds: TimeInterval = 120

    static func time(_ s: String?) -> Date? {
        guard let s else { return nil }
        return (try? Timestamps.parseMillis(s)) ?? (try? Timestamps.parseSeconds(s))
    }

    /// The conversation's calls of [list]. The vault's own count of entries it could not read ([CallList.skipped], which does not
    /// say whose they are) shows for every conversation, as vettid-android does for an entry without a connection.
    static func history(_ list: CallList?, connectionId: String, now: Date) -> CallHistory {
        guard let list else { return CallHistory() }
        let mine = list.calls.filter { $0.connectionId == connectionId }
        var entries: [CallHistoryEntry] = []
        var unreadable = false
        for r in mine {
            guard let started = time(r.startedAt) else {
                unreadable = true
                continue
            }
            guard let outcome = outcome(r, now: now) else { continue }
            var duration: Duration?
            if let answered = time(r.answeredAt), let ended = time(r.endedAt) {
                duration = Duration.rounded(seconds: ended.timeIntervalSince(answered))
            }
            entries.append(CallHistoryEntry(
                callId: r.callId, connectionId: r.connectionId, outgoing: r.direction == "out", outcome: outcome, startedAt: started,
                duration: duration
            ))
        }
        return CallHistory(entries: entries, someNotShown: list.skipped > 0 || unreadable)
    }

    /// How [r] ended, or nil when it has no row: answered on another device, or going on (answered and not over, or ringing
    /// within ``ringStale``).
    static func outcome(_ r: CallRecord, now: Date) -> CallOutcome? {
        guard let started = time(r.startedAt) else { return nil }
        let outgoing = r.direction == "out"
        let answered = time(r.answeredAt)
        let ended = time(r.endedAt)
        if answered != nil, ended != nil { return .talked }
        if answered != nil { return nil }
        if r.state == "ringing" {
            if now.timeIntervalSince(started) <= ringStaleSeconds { return nil }
            return outgoing ? .notAnswered : .missed
        }
        return outgoing ? outgoingEnd(r.reason) : incomingEnd(r.reason)
    }

    private static func outgoingEnd(_ reason: String?) -> CallOutcome {
        switch reason {
        case CallReason.decline: .declined
        case CallReason.busy: .busy
        case CallReason.timeout, CallReason.hangup: .notAnswered
        default: .failed
        }
    }

    private static func incomingEnd(_ reason: String?) -> CallOutcome? {
        switch reason {
        case CallReason.decline: .declinedHere
        case CallReason.answeredElsewhere: nil
        case CallReason.failed: .failed
        default: .missed
        }
    }
}
