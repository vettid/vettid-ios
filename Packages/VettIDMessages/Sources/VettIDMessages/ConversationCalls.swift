import Foundation
import VettIDData

// The calls of a conversation (vettid-android `CallEntries.kt` and the calls of `ConversationViewModel`). The calls package
// (`VettIDCalls`) reads the vault's `call.list`; this package does not depend on it, so the app maps its history into these
// types and hands the conversation a ``ConversationCalls``.

/// How a past call ended, as a conversation's line says it. A call answered on another of the member's devices, and one still
/// going on, have no line, so they are not here.
public enum ConversationCallOutcome: Equatable, Sendable {
    case talked, declined, declinedHere, busy, notAnswered, missed, failed
}

/// One call of the vault's history with this connection (no content, no keys).
public struct ConversationCall: Equatable, Sendable {
    public let callId: String
    public let outgoing: Bool
    public let outcome: ConversationCallOutcome
    public let startedAt: Date
    /// How long the call was answered for; nil if it never was.
    public let duration: TimeInterval?

    public init(callId: String, outgoing: Bool, outcome: ConversationCallOutcome, startedAt: Date, duration: TimeInterval? = nil) {
        self.callId = callId
        self.outgoing = outgoing
        self.outcome = outcome
        self.startedAt = startedAt
        self.duration = duration
    }
}

/// The calls with one connection, and whether the vault's list had entries that did not read ("Some calls couldn't be
/// shown.", in every conversation: owner decision, Ground Control #10659 a, since the vault only counts them).
public struct ConversationCallHistory: Equatable, Sendable {
    public var calls: [ConversationCall]
    public var someNotShown: Bool

    public init(calls: [ConversationCall] = [], someNotShown: Bool = false) {
        self.calls = calls
        self.someNotShown = someNotShown
    }
}

/// What the calls give a conversation. Mirrors vettid-android `CallAvailability`, without `NOT_IN_BUILD` (a build without calls
/// has no ``ConversationCalls``) and with the vault that has no calls, and the one not asked yet, as ``unavailable``: the Call
/// action is hidden for both (owner decision #10677; vettid-android shows a "not in vault" note on a tap instead).
public enum ConversationCallAvailability: Equatable, Sendable {
    case unavailable
    case ready
    /// A call is going on: no action, and the calls already read stay.
    case inCall
}

/// The app's calls, as a conversation uses them.
public struct ConversationCalls: Sendable {
    /// Read where it is used, so that a change of the answer is followed (the host is observable).
    public var availability: @MainActor @Sendable () -> ConversationCallAvailability
    /// The calls with a connection, newest first.
    public var history: @MainActor @Sendable (String) async -> ConversationCallHistory
    /// A tap on the Call action: through the microphone gate and the machine.
    public var call: @MainActor @Sendable (String) -> Void

    public init(
        availability: @escaping @MainActor @Sendable () -> ConversationCallAvailability,
        history: @escaping @MainActor @Sendable (String) async -> ConversationCallHistory,
        call: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.availability = availability
        self.history = history
        self.call = call
    }
}

/// One row of a conversation: a message, or a call.
public enum ConversationRow: Equatable, Sendable, Identifiable {
    case message(MessageInfo)
    case call(ConversationCall)

    public var at: Date {
        switch self {
        case .message(let m): m.sentAt
        case .call(let c): c.startedAt
        }
    }

    public var id: String {
        switch self {
        case .message(let m): m.messageID
        case .call(let c): "call-\(c.callId)"
        }
    }
}

/// A duration as its two largest parts.
public struct CallDurationParts: Equatable, Sendable {
    public let hours: Int
    public let minutes: Int
    public let seconds: Int

    public init(hours: Int, minutes: Int, seconds: Int) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
    }

    public init(_ d: TimeInterval) {
        let s = Int(max(0, d).rounded(.down))
        hours = s / 3_600
        minutes = s % 3_600 / 60
        seconds = s % 60
    }
}

public enum CallEntries {
    /// Messages and calls in one list, oldest first (a message before a call of the same instant). [notBefore]: when older
    /// messages remain in the vault the list starts at its oldest loaded message, so a call before it is left out (it would
    /// hang above the messages with nothing around it); it comes back with the older page.
    public static func rows(_ messages: [MessageInfo], _ calls: [ConversationCall], notBefore: Date? = nil) -> [ConversationRow] {
        // Without calls the messages keep the vault's order.
        if calls.isEmpty { return messages.map(ConversationRow.message) }
        let shown = calls.filter { call in notBefore.map { call.startedAt >= $0 } ?? true }
        let all = messages.map(ConversationRow.message) + shown.map(ConversationRow.call)
        // `sorted` is not stable: the index keeps ties in order.
        return all.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
    }
}
