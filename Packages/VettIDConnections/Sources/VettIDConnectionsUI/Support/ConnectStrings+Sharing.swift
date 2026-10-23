import Foundation

/// A connection's sharing cards (vettid-android `feature/connections` `strings.xml`, word for word, under its string names):
/// what the member shares with it, what it shares with the member (VAULT-MESSAGING §10.12), and how a rule is named.
extension ConnectStrings {
    static func shareOutTitle(_ name: String) -> String {
        String(localized: "connections_share_out_title", defaultValue: "You share with \(name)", bundle: .module)
    }

    static var shareOutTitleUnnamed: String {
        String(
            localized: "connections_share_out_title_unnamed",
            defaultValue: "You share with this connection",
            bundle: .module
        )
    }

    static func shareOutEmpty(_ name: String) -> String {
        String(
            localized: "connections_share_out_empty",
            defaultValue: "You’re not sharing anything with \(name) yet.",
            bundle: .module
        )
    }

    static var shareOutEmptyUnnamed: String {
        String(
            localized: "connections_share_out_empty_unnamed",
            defaultValue: "You’re not sharing anything with this connection yet.",
            bundle: .module
        )
    }

    static var shareOutRules: String { String(localized: "connections_share_out_rules", defaultValue: "Rules", bundle: .module) }

    static var shareOutItems: String {
        String(
            localized: "connections_share_out_items",
            defaultValue: "Items they can see now",
            bundle: .module
        )
    }

    static var shareOutAction: String {
        String(
            localized: "connections_share_out_action",
            defaultValue: "Add a rule",
            bundle: .module
        )
    }

    static var shareOutManage: String {
        String(
            localized: "connections_share_out_manage",
            defaultValue: "Manage what you share",
            bundle: .module
        )
    }

    static func shareOutCount(_ count: Int) -> String {
        String(localized: "connections_share_out_count", defaultValue: "\(count) items shared", bundle: .module)
    }

    static func shareInTitle(_ name: String) -> String {
        String(localized: "connections_share_in_title", defaultValue: "\(name) shares with you", bundle: .module)
    }

    static var shareInTitleUnnamed: String {
        String(
            localized: "connections_share_in_title_unnamed",
            defaultValue: "This connection shares with you",
            bundle: .module
        )
    }

    static func shareInEmpty(_ name: String) -> String {
        String(
            localized: "connections_share_in_empty",
            defaultValue: "\(name) isn’t sharing anything with you yet.",
            bundle: .module
        )
    }

    static var shareInEmptyUnnamed: String {
        String(
            localized: "connections_share_in_empty_unnamed",
            defaultValue: "This connection isn’t sharing anything with you yet.",
            bundle: .module
        )
    }

    static var shareInAction: String {
        String(
            localized: "connections_share_in_action",
            defaultValue: "Ask for something",
            bundle: .module
        )
    }

    static var shareInOpen: String {
        String(
            localized: "connections_share_in_open",
            defaultValue: "See what is shared with you",
            bundle: .module
        )
    }

    static func shareInCount(_ count: Int) -> String {
        String(localized: "connections_share_in_count", defaultValue: "\(count) items shared with you", bundle: .module)
    }

    static func shareInAsked(_ count: Int) -> String {
        String(
            localized: "connections_share_in_asked",
            defaultValue: "You asked for \(count) things; waiting for an answer.",
            bundle: .module
        )
    }

    static var shareUnavailable: String {
        String(
            localized: "connections_share_unavailable",
            defaultValue: "Sharing could not be read just now.",
            bundle: .module
        )
    }

    static var shareRuleAsk: String {
        String(
            localized: "connections_share_rule_ask",
            defaultValue: "Asks you each time",
            bundle: .module
        )
    }

    static var shareRuleAuto: String {
        String(
            localized: "connections_share_rule_auto",
            defaultValue: "Shared automatically",
            bundle: .module
        )
    }

    static var shareRuleAll: String {
        String(
            localized: "connections_share_rule_all",
            defaultValue: "Items with all of these tags",
            bundle: .module
        )
    }

    static var shareRuleAny: String {
        String(
            localized: "connections_share_rule_any",
            defaultValue: "Items with any of these tags",
            bundle: .module
        )
    }

    static var shareNoLimit: String {
        String(
            localized: "connections_share_no_limit",
            defaultValue: "no fetch limit",
            bundle: .module
        )
    }

    static var shareNoEnd: String { String(localized: "connections_share_no_end", defaultValue: "no end date", bundle: .module) }

    static func shareRuleIncluded(_ count: Int) -> String {
        String(localized: "connections_share_rule_included", defaultValue: "\(count) items shared now", bundle: .module)
    }

    static func shareRuleOverlaps(_ name: String) -> String {
        String(localized: "connections_share_rule_overlaps", defaultValue: "Overlaps \(name)", bundle: .module)
    }

    static func shareRuleAsksFirstFor(_ name: String) -> String {
        String(
            localized: "connections_share_rule_asks_first_for",
            defaultValue: "Asks you first for the items \(name) also covers",
            bundle: .module
        )
    }

    static func ruleName(_ name: String) -> String {
        String(localized: "connections_rule_name", defaultValue: "your “\(name)” rule", bundle: .module)
    }

    static func ruleNameAsks(_ name: String) -> String {
        String(localized: "connections_rule_name_asks", defaultValue: "your “\(name)” rule (asks first)", bundle: .module)
    }

    static func ruleNameAuto(_ name: String) -> String {
        String(
            localized: "connections_rule_name_auto",
            defaultValue: "your “\(name)” rule (shares automatically)",
            bundle: .module
        )
    }

    static func ruleNameUntil(_ name: String, _ day: String) -> String {
        String(localized: "connections_rule_name_until", defaultValue: "your “\(name)” rule (until \(day))", bundle: .module)
    }

    static func ruleNameNoEnd(_ name: String) -> String {
        String(localized: "connections_rule_name_no_end", defaultValue: "your “\(name)” rule (no end date)", bundle: .module)
    }

    static func sharePerHour(_ count: Int) -> String {
        String(localized: "connections_share_per_hour", defaultValue: "up to \(count) an hour", bundle: .module)
    }

    static func sharePerDay(_ count: Int) -> String {
        String(localized: "connections_share_per_day", defaultValue: "up to \(count) a day", bundle: .module)
    }

    static func shareReceivedPerHour(_ count: Int) -> String {
        String(localized: "connections_share_received_per_hour", defaultValue: "up to \(count) times an hour", bundle: .module)
    }

    static func shareReceivedPerDay(_ count: Int) -> String {
        String(localized: "connections_share_received_per_day", defaultValue: "up to \(count) times a day", bundle: .module)
    }

    static var shareRuleDelete: String {
        String(
            localized: "connections_share_rule_delete",
            defaultValue: "Delete this rule",
            bundle: .module
        )
    }

    static var shareRuleDeleteTitle: String {
        String(
            localized: "connections_share_rule_delete_title",
            defaultValue: "Delete this sharing rule?",
            bundle: .module
        )
    }

    static func shareRuleDeleteBody(_ name: String) -> String {
        String(
            localized: "connections_share_rule_delete_body",
            defaultValue: """
                \(name) can no longer fetch the items this rule shared. Items another rule shares stay shared, and \
                nothing becomes shared because this rule is gone.
                """,
            bundle: .module
        )
    }

    static var shareRuleDeleteUnnamed: String {
        String(
            localized: "connections_share_rule_delete_unnamed",
            defaultValue: """
                This connection can no longer fetch the items this rule shared. Items another rule shares stay shared, and \
                nothing becomes shared because this rule is gone.
                """,
            bundle: .module
        )
    }

    static var shareRuleOpen: String {
        String(
            localized: "connections_share_rule_open",
            defaultValue: "Change this rule",
            bundle: .module
        )
    }

    static func shareRulePending(_ count: Int) -> String {
        String(localized: "connections_share_rule_pending", defaultValue: "\(count) waiting for you", bundle: .module)
    }

    static func shareUses(_ count: Int) -> String {
        String(localized: "connections_share_uses", defaultValue: "up to \(count) fetches of each item", bundle: .module)
    }

    static func shareUsesLeft(_ count: Int) -> String {
        String(localized: "connections_share_uses_left", defaultValue: "\(count) uses left", bundle: .module)
    }

    static func shareUntil(_ name: String) -> String {
        String(localized: "connections_share_until", defaultValue: "until \(name)", bundle: .module)
    }

    static var shareByRule: String {
        String(
            localized: "connections_share_by_rule",
            defaultValue: "From a rule",
            bundle: .module
        )
    }

    static var shareOneOff: String {
        String(
            localized: "connections_share_one_off",
            defaultValue: "Shared once",
            bundle: .module
        )
    }

    static var shareDeletedItem: String {
        String(
            localized: "connections_share_deleted_item",
            defaultValue: "Deleted item",
            bundle: .module
        )
    }

    static func shareTheirs(_ name: String) -> String {
        String(localized: "connections_share_theirs", defaultValue: "\(name)’s", bundle: .module)
    }
}
