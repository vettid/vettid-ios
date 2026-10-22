import Foundation

// The sharing screens' texts, continued (``ItemsStrings``), generated from the table's keys: vettid-android
// `strings_sharing.xml`, word for word. A plural is the table's variation of the count.
public extension ItemsStrings {
    static func ruleAsksFirstFor(_ a: String) -> String {
        String(
            localized: "items_rule_asks_first_for",
            defaultValue: "Asks you first for the items \(a) also covers",
            bundle: .module
        )
    }

    static var ruleOverlapTitle: String {
        String(
            localized: "items_rule_overlap_title",
            defaultValue: "Your other rules for these items",
            bundle: .module
        )
    }

    static func ruleOverlapTags(_ a: String) -> String {
        String(localized: "items_rule_overlap_tags", defaultValue: "also names \(a)", bundle: .module)
    }

    static func ruleOverlapItems(_ a: Int) -> String {
        String(localized: "items_rule_overlap_items", defaultValue: "\(a) of these items are in it", bundle: .module)
    }

    static var ruleOverlapNote: String {
        String(
            localized: "items_rule_overlap_note",
            defaultValue: """
                When rules overlap, asking wins: an item that any of them asks about is shared only after you \
                approve it, and your answer counts for all of them. The strictest fetch limits apply.
                """,
            bundle: .module
        )
    }

    static func ruleNameAsks(_ a: String) -> String {
        String(localized: "items_rule_name_asks", defaultValue: "your “\(a)” rule (asks first)", bundle: .module)
    }

    static func ruleNameAuto(_ a: String) -> String {
        String(localized: "items_rule_name_auto", defaultValue: "your “\(a)” rule (shares automatically)", bundle: .module)
    }

    static func ruleNameUntil(_ a: String, _ b: String) -> String {
        String(localized: "items_rule_name_until", defaultValue: "your “\(a)” rule (until \(b))", bundle: .module)
    }

    static func ruleNameNoEnd(_ a: String) -> String {
        String(localized: "items_rule_name_no_end", defaultValue: "your “\(a)” rule (no end date)", bundle: .module)
    }

    static func ruleOutcomeAskBecause(_ a: String) -> String {
        String(
            localized: "items_rule_outcome_ask_because",
            defaultValue: "Asks you first because \(a) covers it",
            bundle: .module
        )
    }

    static var ruleOutcomeInclude: String {
        String(
            localized: "items_rule_outcome_include",
            defaultValue: "Shared at once",
            bundle: .module
        )
    }

    static var ruleOutcomeAsk: String {
        String(
            localized: "items_rule_outcome_ask",
            defaultValue: "You will be asked",
            bundle: .module
        )
    }

    static var ruleStateIncluded: String {
        String(
            localized: "items_rule_state_included",
            defaultValue: "Already shared",
            bundle: .module
        )
    }

    static var ruleStatePending: String {
        String(
            localized: "items_rule_state_pending",
            defaultValue: "Waiting for your decision",
            bundle: .module
        )
    }

    static var ruleStateDeclined: String {
        String(
            localized: "items_rule_state_declined",
            defaultValue: "Not shared: you declined it",
            bundle: .module
        )
    }

    static func rulePreviewMatch(_ a: Int) -> String {
        String(localized: "items_rule_preview_match", defaultValue: "\(a) items match", bundle: .module)
    }

    static func rulePreviewOutcomeInclude(_ a: Int) -> String {
        String(localized: "items_rule_preview_outcome_include", defaultValue: "\(a) shared at once", bundle: .module)
    }

    static func rulePreviewOutcomeAsk(_ a: Int) -> String {
        String(localized: "items_rule_preview_outcome_ask", defaultValue: "\(a) ask you first", bundle: .module)
    }

    static func rulePreviewOutcomes(_ a: String, _ b: String) -> String {
        String(localized: "items_rule_preview_outcomes", defaultValue: "\(a): \(b).", bundle: .module)
    }

    static func ruleUntil(_ a: String) -> String {
        String(localized: "items_rule_until", defaultValue: "until \(a)", bundle: .module)
    }

    static func ruleUsesPlural(_ a: Int) -> String {
        String(localized: "items_rule_uses_plural", defaultValue: "up to \(a) fetches of each item", bundle: .module)
    }

    static func ruleIncluded(_ a: Int) -> String {
        String(localized: "items_rule_included", defaultValue: "\(a) shared", bundle: .module)
    }

    static func rulePending(_ a: Int) -> String {
        String(localized: "items_rule_pending", defaultValue: "\(a) waiting", bundle: .module)
    }

    static func ruleDeclined(_ a: Int) -> String {
        String(localized: "items_rule_declined", defaultValue: "\(a) declined", bundle: .module)
    }

    static var ruleChange: String { String(localized: "items_rule_change", defaultValue: "Change", bundle: .module) }

    static var ruleSave: String { String(localized: "items_rule_save", defaultValue: "Save rule", bundle: .module) }

    static var ruleDelete: String { String(localized: "items_rule_delete", defaultValue: "Delete rule", bundle: .module) }

    static var ruleDeleteTitle: String {
        String(
            localized: "items_rule_delete_title",
            defaultValue: "Delete this sharing rule?",
            bundle: .module
        )
    }

    static func ruleDeleteBody(_ a: String) -> String {
        String(
            localized: "items_rule_delete_body",
            defaultValue: """
                \(a) can no longer fetch the items it shared. Items another rule shares stay shared, and nothing \
                becomes shared because this rule is gone.
                """,
            bundle: .module
        )
    }

    static var rulePreview: String {
        String(
            localized: "items_rule_preview",
            defaultValue: "What it matches now",
            bundle: .module
        )
    }

    static var rulePreviewNone: String {
        String(
            localized: "items_rule_preview_none",
            defaultValue: "Choose a tag",
            bundle: .module
        )
    }

    static func rulePreviewAsk(_ a: Int) -> String {
        String(
            localized: "items_rule_preview_ask",
            defaultValue: "\(a) items match: you will be asked about each.",
            bundle: .module
        )
    }

    static func rulePreviewAuto(_ a: Int) -> String {
        String(localized: "items_rule_preview_auto", defaultValue: "\(a) items match and will be shared.", bundle: .module)
    }

    static var rulePreviewLater: String {
        String(
            localized: "items_rule_preview_later",
            defaultValue: "They count only if they get a tag again; new items count from now.",
            bundle: .module
        )
    }

    static func rulePreviewUsable(_ a: String) -> String {
        String(
            localized: "items_rule_preview_usable",
            defaultValue: "\(a) (critical: usable only, never readable)",
            bundle: .module
        )
    }

    static func rulePreviewMore(_ a: Int) -> String {
        String(localized: "items_rule_preview_more", defaultValue: "and \(a) more", bundle: .module)
    }

    static func sharedHolds(_ a: String) -> String {
        String(localized: "items_shared_holds", defaultValue: "Holds: \(a)", bundle: .module)
    }

    static func askEntryCategory(_ a: String) -> String {
        String(localized: "items_ask_entry_category", defaultValue: "\(a) (any item)", bundle: .module)
    }

    static var askEntryItem: String { String(localized: "items_ask_entry_item", defaultValue: "an item", bundle: .module) }

    static func sharedTitle(_ a: String) -> String {
        String(localized: "items_shared_title", defaultValue: "Shared by \(a)", bundle: .module)
    }

    static func sharedBody(_ a: String) -> String {
        String(
            localized: "items_shared_body",
            defaultValue: """
                What \(a) shares with you, as they entered it. It is theirs: you can read it here, not change it.
                """,
            bundle: .module
        )
    }

    static func sharedNone(_ a: String) -> String {
        String(localized: "items_shared_none", defaultValue: "\(a) shares nothing with you.", bundle: .module)
    }

    static func sharedBy(_ a: String) -> String {
        String(localized: "items_shared_by", defaultValue: "shared by \(a)", bundle: .module)
    }

    static var sharedFetch: String { String(localized: "items_shared_fetch", defaultValue: "Show", bundle: .module) }

    static var sharedFetching: String { String(localized: "items_shared_fetching", defaultValue: "Asking…", bundle: .module) }

    static var sharedEnded: String { String(localized: "items_shared_ended", defaultValue: "No longer shared", bundle: .module) }

    static var sharedGiveUp: String { String(localized: "items_shared_give_up", defaultValue: "Remove", bundle: .module) }

    static func sharedGiveUpTitle(_ a: String) -> String {
        String(localized: "items_shared_give_up_title", defaultValue: "Remove \(a)?", bundle: .module)
    }

    static func sharedGiveUpBody(_ a: String) -> String {
        String(
            localized: "items_shared_give_up_body",
            defaultValue: "You can no longer see it, and \(a) is told.",
            bundle: .module
        )
    }

    static var sharedRefusedRevoked: String {
        String(
            localized: "items_shared_refused_revoked",
            defaultValue: "They stopped sharing it.",
            bundle: .module
        )
    }

    static var sharedRefusedExpired: String {
        String(
            localized: "items_shared_refused_expired",
            defaultValue: "The sharing ended.",
            bundle: .module
        )
    }

    static var sharedRefusedExhausted: String {
        String(
            localized: "items_shared_refused_exhausted",
            defaultValue: "No fetches are left.",
            bundle: .module
        )
    }

    static var sharedRefusedUnavailable: String {
        String(
            localized: "items_shared_refused_unavailable",
            defaultValue: "It is not available any more.",
            bundle: .module
        )
    }

    static func sharedRefusedRateLimited(_ a: String) -> String {
        String(
            localized: "items_shared_refused_rate_limited",
            defaultValue: "Opened as often as \(a) allows for now.",
            bundle: .module
        )
    }

    static func sharedRetryMinutes(_ a: Int) -> String {
        String(localized: "items_shared_retry_minutes", defaultValue: "Try again in \(a) minutes.", bundle: .module)
    }

    static func sharedRetryHours(_ a: Int) -> String {
        String(localized: "items_shared_retry_hours", defaultValue: "Try again in \(a) hours.", bundle: .module)
    }

    static func grantPerHour(_ a: Int) -> String {
        String(localized: "items_grant_per_hour", defaultValue: "up to \(a) times an hour", bundle: .module)
    }

    static func grantPerDay(_ a: Int) -> String {
        String(localized: "items_grant_per_day", defaultValue: "up to \(a) times a day", bundle: .module)
    }

    static var askTitle: String { String(localized: "items_ask_title", defaultValue: "Ask for something", bundle: .module) }

    static func askButton(_ a: String) -> String {
        String(localized: "items_ask_button", defaultValue: "Ask \(a) for something", bundle: .module)
    }

    static func askCategory(_ a: String) -> String {
        String(localized: "items_ask_category", defaultValue: "Kind: \(a)", bundle: .module)
    }

    static var askLabel: String {
        String(
            localized: "items_ask_label",
            defaultValue: "What you need (for example: your insurance card)",
            bundle: .module
        )
    }

    static var askReason: String { String(localized: "items_ask_reason", defaultValue: "Why (optional)", bundle: .module) }

    static func askNote(_ a: String) -> String {
        String(
            localized: "items_ask_note",
            defaultValue: "\(a) chooses which of their items to share, if any. You see it here once they agree.",
            bundle: .module
        )
    }

    static var askSend: String { String(localized: "items_ask_send", defaultValue: "Ask", bundle: .module) }

    static func askSent(_ a: String) -> String {
        String(localized: "items_ask_sent", defaultValue: "Asked. \(a) decides in their app.", bundle: .module)
    }

    static func askRow(_ a: String, _ b: String) -> String {
        String(localized: "items_ask_row", defaultValue: "\(a): \(b)", bundle: .module)
    }

    static var askStatePending: String { String(localized: "items_ask_state_pending", defaultValue: "waiting", bundle: .module) }

    static var askStateGranted: String { String(localized: "items_ask_state_granted", defaultValue: "shared", bundle: .module) }

    static var askStateDenied: String {
        String(
            localized: "items_ask_state_denied",
            defaultValue: "not accepted",
            bundle: .module
        )
    }
}
