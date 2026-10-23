import Foundation
import VettIDData

// The sharing screens' member-facing names and messages, over the table's accessors (``ItemsStrings``). Mirrors vettid-android
// `SharingScreens` text helpers.
public extension ItemsText {
    /// A rule end's choice as the editor lists it.
    static func expiry(_ e: RuleExpiry) -> String {
        switch e {
        case .never: ItemsStrings.ruleExpiryNever
        case .day: ItemsStrings.ruleExpiryDay
        case .week: ItemsStrings.ruleExpiryWeek
        case .month: ItemsStrings.ruleExpiryMonth
        case .threeMonths: ItemsStrings.ruleExpiryThreeMonths
        case .year: ItemsStrings.ruleExpiryYear
        case .custom, .keep: ItemsStrings.ruleExpiryCustom
        }
    }

    /// "Try again in 12 minutes", or in hours from 90 minutes, for a refusal ending at [until].
    static func retry(until: Date, now: Date = Date()) -> String {
        let r = RetryIn.of(Int64(until.timeIntervalSince(now).rounded(.down)))
        return r.scale == .hours ? ItemsStrings.sharedRetryHours(r.count) : ItemsStrings.sharedRetryMinutes(r.count)
    }

    /// Why the connection's vault refused a fetch (`revoked`, `expired`, `exhausted`, `rate_limited`; anything else reads as
    /// `unavailable`); [name] the connection's, isolated.
    static func refusal(_ why: String, name: String) -> String {
        switch why {
        case "revoked": ItemsStrings.sharedRefusedRevoked
        case "expired": ItemsStrings.sharedRefusedExpired
        case "exhausted": ItemsStrings.sharedRefusedExhausted
        case FetchOutcome.rateLimited: ItemsStrings.sharedRefusedRateLimited(name)
        default: ItemsStrings.sharedRefusedUnavailable
        }
    }

    /// A request this vault made, by its state (`granted` and `approved` read as shared, `denied` as denied; anything else
    /// as waiting, as vettid-android's screen reads them).
    static func askState(_ state: String) -> String {
        switch state {
        case "granted", "approved": ItemsStrings.askStateGranted
        case "denied": ItemsStrings.askStateDenied
        default: ItemsStrings.askStatePending
        }
    }
}
