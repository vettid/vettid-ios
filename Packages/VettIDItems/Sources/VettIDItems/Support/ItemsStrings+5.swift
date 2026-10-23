import Foundation

// The sharing screens' texts, first part (``ItemsStrings``), generated from the table's keys: vettid-android
// `strings_sharing.xml`, word for word. A plural is the table's variation of the count.
public extension ItemsStrings {
    static func sharingTitle(_ a: String) -> String {
        String(localized: "items_sharing_title", defaultValue: "What \(a) can see", bundle: .module)
    }

    static func sharingBody(_ a: String) -> String {
        String(
            localized: "items_sharing_body",
            defaultValue: "\(a) sees only the items you share, never your tags or rules.",
            bundle: .module
        )
    }

    static var sharingRules: String { String(localized: "items_sharing_rules", defaultValue: "Sharing by tag", bundle: .module) }

    static func sharingNoRules(_ a: String) -> String {
        String(localized: "items_sharing_no_rules", defaultValue: "You share nothing with \(a) by tag.", bundle: .module)
    }

    static var sharingNewRule: String { String(localized: "items_sharing_new_rule", defaultValue: "Add a rule", bundle: .module) }

    static var sharingPendingTitle: String {
        String(
            localized: "items_sharing_pending_title",
            defaultValue: "Waiting for you",
            bundle: .module
        )
    }

    static func sharingPendingBody(_ a: Int) -> String {
        String(
            localized: "items_sharing_pending_body",
            defaultValue: "\(a) items wait for your decision in Approvals.",
            bundle: .module
        )
    }

    static func sharingCanSee(_ a: String) -> String {
        String(localized: "items_sharing_can_see", defaultValue: "What \(a) can fetch now", bundle: .module)
    }

    static func sharingNothing(_ a: String) -> String {
        String(localized: "items_sharing_nothing", defaultValue: "\(a) can fetch nothing from your vault.", bundle: .module)
    }

    static func sharingUsable(_ a: String) -> String {
        String(localized: "items_sharing_usable", defaultValue: "\(a): can ask you to use it, never read it", bundle: .module)
    }

    static var sharingRevoke: String { String(localized: "items_sharing_revoke", defaultValue: "Revoke", bundle: .module) }

    static func sharingRevokeTitle(_ a: String) -> String {
        String(localized: "items_sharing_revoke_title", defaultValue: "Stop sharing \(a)?", bundle: .module)
    }

    static func sharingRevokeBody(_ a: String) -> String {
        String(localized: "items_sharing_revoke_body", defaultValue: "\(a) can no longer fetch it.", bundle: .module)
    }

    static func sharingRevokeBodyRule(_ a: String) -> String {
        String(
            localized: "items_sharing_revoke_body_rule",
            defaultValue: """
                \(a) can no longer fetch it. The sharing rule stays as it is: change the item's tags or the rule to \
                keep it from being shared again.
                """,
            bundle: .module
        )
    }

    static var deletedItem: String { String(localized: "items_deleted_item", defaultValue: "Deleted item", bundle: .module) }

    static var grantByRule: String { String(localized: "items_grant_by_rule", defaultValue: "By a tag rule", bundle: .module) }

    static var grantOneOff: String { String(localized: "items_grant_one_off", defaultValue: "Asked for once", bundle: .module) }

    static func grantUsesLeft(_ a: Int) -> String {
        String(localized: "items_grant_uses_left", defaultValue: "\(a) fetches left", bundle: .module)
    }

    static var ruleNewTitle: String {
        String(
            localized: "items_rule_new_title",
            defaultValue: "New sharing rule",
            bundle: .module
        )
    }

    static var ruleEditTitle: String { String(localized: "items_rule_edit_title", defaultValue: "Sharing rule", bundle: .module) }

    static func ruleBody(_ a: String) -> String {
        String(
            localized: "items_rule_body",
            defaultValue: "Each rule shares one tag with \(a) and has its own settings. Your tags stay private.",
            bundle: .module
        )
    }

    static var ruleTagTitle: String {
        String(
            localized: "items_rule_tag_title",
            defaultValue: "Select the tag to share",
            bundle: .module
        )
    }

    static func ruleTagHint(_ a: String) -> String {
        String(localized: "items_rule_tag_hint", defaultValue: "Items with this tag will be shared with \(a)", bundle: .module)
    }

    static var ruleTagTakenTitle: String {
        String(
            localized: "items_rule_tag_taken_title",
            defaultValue: "Already shared",
            bundle: .module
        )
    }

    static var ruleTagTaken: String {
        String(
            localized: "items_rule_tag_taken",
            defaultValue: "Already shared — edit its rule",
            bundle: .module
        )
    }

    static func ruleTagTakenCd(_ a: String) -> String {
        String(localized: "items_rule_tag_taken_cd", defaultValue: "\(a): already shared — edit its rule", bundle: .module)
    }

    static var ruleMultiTitle: String {
        String(
            localized: "items_rule_multi_title",
            defaultValue: "This rule names several tags",
            bundle: .module
        )
    }

    static var ruleMultiBody: String {
        String(
            localized: "items_rule_multi_body",
            defaultValue: """
                Rules now share one tag each. This rule stays as it is: you can delete it and add a rule for each \
                tag instead.
                """,
            bundle: .module
        )
    }

    static var ruleDiscardTitle: String {
        String(
            localized: "items_rule_discard_title",
            defaultValue: "Discard changes to this rule?",
            bundle: .module
        )
    }

    static var ruleNoTags: String {
        String(
            localized: "items_rule_no_tags",
            defaultValue: "Add tags to your items first: a rule shares by tag.",
            bundle: .module
        )
    }

    static var ruleMatchAnyShort: String {
        String(
            localized: "items_rule_match_any_short",
            defaultValue: "Any of these tags",
            bundle: .module
        )
    }

    static var ruleMatchAllShort: String {
        String(
            localized: "items_rule_match_all_short",
            defaultValue: "All of these tags",
            bundle: .module
        )
    }

    static var ruleMode: String {
        String(
            localized: "items_rule_mode",
            defaultValue: "When an item gets this tag",
            bundle: .module
        )
    }

    static var ruleModeAsk: String { String(localized: "items_rule_mode_ask", defaultValue: "Ask me each time", bundle: .module) }

    static var ruleModeAskNote: String {
        String(
            localized: "items_rule_mode_ask_note",
            defaultValue: "You decide about each item in Approvals before it is shared",
            bundle: .module
        )
    }

    static var ruleModeAuto: String {
        String(
            localized: "items_rule_mode_auto",
            defaultValue: "Share automatically",
            bundle: .module
        )
    }

    static var ruleModeAutoNote: String {
        String(
            localized: "items_rule_mode_auto_note",
            defaultValue: """
                New items with this tag are shared at once, unless another of your rules for them asks first
                """,
            bundle: .module
        )
    }

    static var ruleExisting: String {
        String(
            localized: "items_rule_existing",
            defaultValue: "Include items that already have this tag",
            bundle: .module
        )
    }

    static var ruleExistingNote: String {
        String(
            localized: "items_rule_existing_note",
            defaultValue: "Off: only items that get this tag from now on",
            bundle: .module
        )
    }

    static var ruleLimits: String { String(localized: "items_rule_limits", defaultValue: "Limits", bundle: .module) }

    static var ruleUses: String {
        String(
            localized: "items_rule_uses",
            defaultValue: "Fetches of each item (optional)",
            bundle: .module
        )
    }

    static var ruleUsesNote: String {
        String(
            localized: "items_rule_uses_note",
            defaultValue: "Empty: no limit. Every fetch is recorded.",
            bundle: .module
        )
    }

    static var ruleUsesBad: String {
        String(
            localized: "items_rule_uses_bad",
            defaultValue: "Between 1 and 10,000",
            bundle: .module
        )
    }

    static var rulePerHour: String {
        String(
            localized: "items_rule_per_hour",
            defaultValue: "Fetches per hour (optional)",
            bundle: .module
        )
    }

    static var rulePerDay: String {
        String(
            localized: "items_rule_per_day",
            defaultValue: "Fetches per day (optional)",
            bundle: .module
        )
    }

    static var rulePerNote: String {
        String(
            localized: "items_rule_per_note",
            defaultValue: "All of this rule's items together. Empty: no limit.",
            bundle: .module
        )
    }

    static var rulePerHourBad: String {
        String(
            localized: "items_rule_per_hour_bad",
            defaultValue: "Between 1 and 3,600",
            bundle: .module
        )
    }

    static var rulePerDayBad: String {
        String(
            localized: "items_rule_per_day_bad",
            defaultValue: "Between 1 and 86,400",
            bundle: .module
        )
    }

    static func rulePerHourSummary(_ a: Int) -> String {
        String(localized: "items_rule_per_hour_summary", defaultValue: "up to \(a) an hour", bundle: .module)
    }

    static func rulePerDaySummary(_ a: Int) -> String {
        String(localized: "items_rule_per_day_summary", defaultValue: "up to \(a) a day", bundle: .module)
    }

    static var ruleExpiry: String { String(localized: "items_rule_expiry", defaultValue: "Ends", bundle: .module) }

    static var ruleExpiryNever: String { String(localized: "items_rule_expiry_never", defaultValue: "Never", bundle: .module) }

    static var ruleExpiryDay: String { String(localized: "items_rule_expiry_day", defaultValue: "1 day", bundle: .module) }

    static var ruleExpiryWeek: String { String(localized: "items_rule_expiry_week", defaultValue: "1 week", bundle: .module) }

    static var ruleExpiryMonth: String { String(localized: "items_rule_expiry_month", defaultValue: "1 month", bundle: .module) }

    static var ruleExpiryThreeMonths: String {
        String(
            localized: "items_rule_expiry_three_months",
            defaultValue: "3 months",
            bundle: .module
        )
    }

    static var ruleExpiryYear: String { String(localized: "items_rule_expiry_year", defaultValue: "1 year", bundle: .module) }

    static var ruleExpiryCustom: String {
        String(
            localized: "items_rule_expiry_custom",
            defaultValue: "Custom…",
            bundle: .module
        )
    }

    static var ruleEndsNever: String {
        String(
            localized: "items_rule_ends_never",
            defaultValue: "No end date: the rule lasts until you delete it.",
            bundle: .module
        )
    }

    static func ruleEndsAt(_ a: String) -> String {
        String(localized: "items_rule_ends_at", defaultValue: "Ends \(a) (your time)", bundle: .module)
    }

    static var ruleEndBad: String {
        String(
            localized: "items_rule_end_bad",
            defaultValue: "Pick a time in the future, at most 10 years ahead.",
            bundle: .module
        )
    }

    static var ruleEndNext: String { String(localized: "items_rule_end_next", defaultValue: "Next", bundle: .module) }

    static var ruleEndTime: String { String(localized: "items_rule_end_time", defaultValue: "Ends at", bundle: .module) }

    static var ruleLimitTitle: String {
        String(
            localized: "items_rule_limit_title",
            defaultValue: "No more rules for this connection",
            bundle: .module
        )
    }

    static var ruleSummaryAuto: String {
        String(
            localized: "items_rule_summary_auto",
            defaultValue: "Shared automatically",
            bundle: .module
        )
    }

    static var ruleSummaryAsk: String {
        String(
            localized: "items_rule_summary_ask",
            defaultValue: "Asks you each time",
            bundle: .module
        )
    }

    static var ruleNoLimit: String { String(localized: "items_rule_no_limit", defaultValue: "no fetch limit", bundle: .module) }

    static var ruleNoEnd: String { String(localized: "items_rule_no_end", defaultValue: "no end date", bundle: .module) }

    static func ruleOverlaps(_ a: String) -> String {
        String(localized: "items_rule_overlaps", defaultValue: "Overlaps \(a)", bundle: .module)
    }
}
