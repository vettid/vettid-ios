import Foundation
import VettIDCalls
import VettIDMessages
import VettIDShellUI

/// The calls as a conversation uses them (the Call action and the call lines): the calls package's history mapped into the
/// messages package's types, which do not depend on it.
extension ConversationCallHistory {
    init(_ history: CallHistory) {
        self.init(
            calls: history.entries.map { e in
                ConversationCall(
                    callId: e.callId, outgoing: e.outgoing, outcome: ConversationCallOutcome(e.outcome), startedAt: e.startedAt,
                    duration: e.duration.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
                )
            },
            someNotShown: history.someNotShown
        )
    }
}

extension ConversationCallOutcome {
    init(_ outcome: CallOutcome) {
        switch outcome {
        case .talked: self = .talked
        case .declined: self = .declined
        case .declinedHere: self = .declinedHere
        case .busy: self = .busy
        case .notAnswered: self = .notAnswered
        case .missed: self = .missed
        case .failed: self = .failed
        }
    }
}

extension ConversationCallAvailability {
    init(_ availability: CallAvailability) {
        switch availability {
        case .ready: self = .ready
        case .inCall: self = .inCall
        // The vault has no calls, or was not asked: no action (owner decision #10677).
        case .unknown, .notInVault: self = .unavailable
        }
    }
}

extension ShellCalls {
    /// The calls of the open vault, for the shell: a connection's page and a conversation.
    @MainActor
    init(_ host: CallsHost) {
        self.init(
            canCall: { host.canCall }, call: { host.call($0) },
            availability: { ConversationCallAvailability(host.availability) },
            history: { ConversationCallHistory(await host.history($0)) }
        )
    }
}
