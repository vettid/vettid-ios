import Foundation
import VettIDMessages

// The calls' texts (vettid-android `feature/messages` `strings.xml`, word for word, under its string names; `%1$s` is `%@`).
// Android's `messages_call_not_in_vault` and `messages_calls_off` are not here: the Call action is hidden where the vault has no
// calls (owner decision #10677), and the app has no per-connection call permission yet.
extension MessagesStrings {
    /// The Call action's label.
    static var call: String { String(localized: "messages_call", defaultValue: "Call", bundle: .module) }

    static var callsNotShown: String {
        String(localized: "messages_calls_not_shown", defaultValue: "Some calls couldn't be shown.", bundle: .module)
    }

    /// A read of the history failed and the lines shown were kept (owner decision, Ground Control #11240 a; the same on both apps).
    static var callsOutOfDate: String {
        String(
            localized: "messages_calls_out_of_date", defaultValue: "Calls may be out of date. VettID couldn't check them just now.",
            bundle: .module
        )
    }

    /// A call's line: what became of it; "Call, <duration>" for one that was talked.
    static func callLine(_ call: ConversationCall) -> String {
        switch call.outcome {
        case .talked: String(localized: "messages_call_talked", defaultValue: "Call, \(duration(call.duration))", bundle: .module)
        case .declined: String(localized: "messages_call_declined", defaultValue: "Call declined", bundle: .module)
        case .declinedHere: String(localized: "messages_call_declined_here", defaultValue: "Call you declined", bundle: .module)
        case .busy: String(localized: "messages_call_busy", defaultValue: "Call not answered: busy", bundle: .module)
        case .notAnswered: String(localized: "messages_call_not_answered", defaultValue: "Call not answered", bundle: .module)
        case .missed: String(localized: "messages_call_missed", defaultValue: "Missed call", bundle: .module)
        case .failed: String(localized: "messages_call_failed", defaultValue: "Call failed", bundle: .module)
        }
    }

    /// A duration as its two largest parts: "1 h 4 min", "4 min 12 s", "12 s"; empty for none.
    static func duration(_ d: TimeInterval?) -> String {
        guard let d else { return "" }
        let p = CallDurationParts(d)
        if p.hours > 0 {
            return String(localized: "messages_call_duration_h_min", defaultValue: "\(p.hours) h \(p.minutes) min", bundle: .module)
        }
        if p.minutes > 0 {
            return String(localized: "messages_call_duration_min_s", defaultValue: "\(p.minutes) min \(p.seconds) s", bundle: .module)
        }
        return String(localized: "messages_call_duration_s", defaultValue: "\(p.seconds) s", bundle: .module)
    }
}
