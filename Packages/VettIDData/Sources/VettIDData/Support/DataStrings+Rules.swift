import Foundation

/// The texts of the PIN and password rules and of the named limits (vettid-android `core/data` strings
/// `data_pin_problem_*`, `data_password_*`, `data_strength_*`, `data_limit_*`).
extension DataStrings {
    static var pinProblemDigits: String { String(localized: "data_pin_problem_digits", defaultValue: "Use digits only.", bundle: .module) }
    static func pinProblemShort(_ n: Int) -> String {
        String(localized: "data_pin_problem_short", defaultValue: "Use at least \(n) digits.", bundle: .module)
    }
    static func pinProblemLong(_ n: Int) -> String {
        String(localized: "data_pin_problem_long", defaultValue: "Use at most \(n) digits.", bundle: .module)
    }
    static var pinProblemRepeated: String {
        String(localized: "data_pin_problem_repeated", defaultValue: "Do not repeat one digit.", bundle: .module)
    }
    static var pinProblemSequence: String {
        String(localized: "data_pin_problem_sequence", defaultValue: "Avoid runs like 123456.", bundle: .module)
    }
    static var pinProblemPattern: String {
        String(localized: "data_pin_problem_pattern", defaultValue: "Avoid repeated patterns like 121212.", bundle: .module)
    }
    static var pinProblemCommon: String {
        String(localized: "data_pin_problem_common", defaultValue: "This PIN is too common.", bundle: .module)
    }
    static var passwordProblemShort: String {
        String(localized: "data_password_problem_short", defaultValue: "Use at least 8 characters.", bundle: .module)
    }
    static var passwordProblemLong: String {
        String(localized: "data_password_problem_long", defaultValue: "This password is too long.", bundle: .module)
    }
    static var passwordProblemWeak: String {
        String(
            localized: "data_password_problem_weak",
            defaultValue: """
                Make it stronger: longer, or a few unrelated words.
                """,
            bundle: .module
        )
    }
    static var passwordProblemPin: String {
        String(localized: "data_password_problem_pin", defaultValue: "Do not reuse your PIN.", bundle: .module)
    }
    static var passwordProblemControl: String {
        String(localized: "data_password_problem_control", defaultValue: "Remove tabs and other control characters.", bundle: .module)
    }
    static var passwordRuleShort: String {
        String(localized: "data_password_rule_short", defaultValue: "Use at least 12 characters.", bundle: .module)
    }
    static var passwordRuleRepeated: String {
        String(localized: "data_password_rule_repeated", defaultValue: "That is one character repeated.", bundle: .module)
    }
    static var passwordRuleCommon: String {
        String(localized: "data_password_rule_common", defaultValue: "That is a very common password.", bundle: .module)
    }
    static var passwordRulePin: String {
        String(localized: "data_password_rule_pin", defaultValue: "Don't use your PIN as your password.", bundle: .module)
    }
    static var passwordRuleGuessable: String {
        String(
            localized: "data_password_rule_guessable",
            defaultValue: """
                This is easy to guess. Add more words or make it less predictable.
                """,
            bundle: .module
        )
    }
    static var passwordRuleGuessableHint: String {
        String(localized: "data_password_rule_guessable_hint", defaultValue: "Avoid names, dates and keyboard runs.", bundle: .module)
    }
    static var passwordRuleOk: String { String(localized: "data_password_rule_ok", defaultValue: "Strong enough.", bundle: .module) }
    static var strengthTooShort: String { String(localized: "data_strength_too_short", defaultValue: "Too short", bundle: .module) }
    static var strengthWeak: String { String(localized: "data_strength_weak", defaultValue: "Weak", bundle: .module) }
    static var strengthFair: String { String(localized: "data_strength_fair", defaultValue: "Fair", bundle: .module) }
    static var strengthGood: String { String(localized: "data_strength_good", defaultValue: "Good", bundle: .module) }
    static var strengthStrong: String { String(localized: "data_strength_strong", defaultValue: "Strong", bundle: .module) }
    static func limitItems(_ n: Int64) -> String {
        String(
            localized: "data_limit_items",
            defaultValue: """
                Your vault is full: it holds at most \(grouped(n)) items. Delete some first.
                """,
            bundle: .module
        )
    }
    static func limitCriticalItems(_ n: Int64) -> String {
        String(
            localized: "data_limit_critical_items",
            defaultValue: """
                Your credential is full: it holds at most \(grouped(n)) critical items.
                """,
            bundle: .module
        )
    }
    static func limitItemSize(_ n: Int64) -> String {
        String(
            localized: "data_limit_item_size",
            defaultValue: """
                This item is too large: an item holds at most \(grouped(n)) KB.
                """,
            bundle: .module
        )
    }
    static func limitItemSizeOf(_ a: Int64, _ b: Int64) -> String {
        String(
            localized: "data_limit_item_size_of",
            defaultValue: """
                This item is too large: \(grouped(a)) KB, and an item holds at most \(grouped(b)) KB.
                """,
            bundle: .module
        )
    }
    static func limitCredentialSize(_ n: Int64) -> String {
        String(
            localized: "data_limit_credential_size",
            defaultValue: """
                Your credential is full: it holds at most \(grouped(n)) KB.
                """,
            bundle: .module
        )
    }
    static func limitCredentialSizeOf(_ a: Int64, _ b: Int64) -> String {
        String(
            localized: "data_limit_credential_size_of",
            defaultValue: """
                Your credential is full: this would make it \(grouped(a)) KB, and it holds at most \(grouped(b)) KB.
                """,
            bundle: .module
        )
    }
    static func limitProfileItems(_ n: Int64) -> String {
        String(
            localized: "data_limit_profile_items",
            defaultValue: """
                Your shared profile is full: it holds at most \(grouped(n)) items.
                """,
            bundle: .module
        )
    }
    static func limitProfileSize(_ n: Int64) -> String {
        String(
            localized: "data_limit_profile_size",
            defaultValue: """
                Your shared profile is too large: it holds at most \(grouped(n)) KB.
                """,
            bundle: .module
        )
    }
    static func limitProfileSizeOf(_ a: Int64, _ b: Int64) -> String {
        String(
            localized: "data_limit_profile_size_of",
            defaultValue: """
                Your shared profile is too large: this would make it \(grouped(a)) KB, and it holds at most \(grouped(b)) KB.
                """,
            bundle: .module
        )
    }
    static func limitTagRegistry(_ n: Int64) -> String {
        String(
            localized: "data_limit_tag_registry",
            defaultValue: """
                Your vault keeps at most \(grouped(n)) tags. Delete one first.
                """,
            bundle: .module
        )
    }
    static func limitAppSettings(_ n: Int64) -> String {
        String(
            localized: "data_limit_app_settings",
            defaultValue: """
                This app keeps at most \(grouped(n)) settings in your vault.
                """,
            bundle: .module
        )
    }
    static func limitShareRulesSubject(_ n: Int64) -> String {
        String(
            localized: "data_limit_share_rules_subject",
            defaultValue: """
                This connection has the most share rules it can have (\(grouped(n))).
                """,
            bundle: .module
        )
    }
    static func limitShareRules(_ n: Int64) -> String {
        String(
            localized: "data_limit_share_rules",
            defaultValue: """
                Your vault has the most share rules it can have (\(grouped(n))). Delete one first.
                """,
            bundle: .module
        )
    }
    static func limitSharePending(_ n: Int64) -> String {
        String(
            localized: "data_limit_share_pending",
            defaultValue: """
                Too many items are waiting for your sharing decision (at most \(grouped(n))). Decide some first.
                """,
            bundle: .module
        )
    }
    static func limitGrantsGiven(_ n: Int64) -> String {
        String(
            localized: "data_limit_grants_given",
            defaultValue: """
                You share the most items you can (\(grouped(n))). Stop sharing some first.
                """,
            bundle: .module
        )
    }
    static func limitGrantRequests(_ n: Int64) -> String {
        String(
            localized: "data_limit_grant_requests",
            defaultValue: """
                You have asked for the most items you can (\(grouped(n)) requests).
                """,
            bundle: .module
        )
    }
    static func limitCatalogRequests(_ n: Int64) -> String {
        String(
            localized: "data_limit_catalog_requests",
            defaultValue: """
                Too many lists of shared items are being fetched (at most \(grouped(n))). Try again later.
                """,
            bundle: .module
        )
    }
    static func limitGrantFetches(_ n: Int64) -> String {
        String(
            localized: "data_limit_grant_fetches",
            defaultValue: """
                Too many shared items are being fetched (at most \(grouped(n))). Try again later.
                """,
            bundle: .module
        )
    }
    static func limitHeldApprovals(_ n: Int64) -> String {
        String(
            localized: "data_limit_held_approvals",
            defaultValue: """
                Too many requests are waiting for your approval (at most \(grouped(n))).
                """,
            bundle: .module
        )
    }
    static func limitConnectionRequests(_ n: Int64) -> String {
        String(
            localized: "data_limit_connection_requests",
            defaultValue: """
                You have sent the most connection requests you can (\(grouped(n)) waiting).
                """,
            bundle: .module
        )
    }
    static func limitBlocks(_ n: Int64) -> String {
        String(
            localized: "data_limit_blocks",
            defaultValue: """
                Your block list is full: it holds at most \(grouped(n)) entries.
                """,
            bundle: .module
        )
    }
    static func limitAuthChallenges(_ n: Int64) -> String {
        String(
            localized: "data_limit_auth_challenges",
            defaultValue: """
                Too many identity checks are waiting for this connection (at most \(grouped(n))).
                """,
            bundle: .module
        )
    }
    static func limitAgentGrants(_ n: Int64) -> String {
        String(
            localized: "data_limit_agent_grants",
            defaultValue: """
                This agent has the most permissions it can have (\(grouped(n))).
                """,
            bundle: .module
        )
    }
    static func limitCriticalUseRequests(_ n: Int64) -> String {
        String(
            localized: "data_limit_critical_use_requests",
            defaultValue: """
                Too many requests to use critical items are waiting (at most \(grouped(n))).
                """,
            bundle: .module
        )
    }
    static func limitActionInvocations(_ n: Int64) -> String {
        String(
            localized: "data_limit_action_invocations",
            defaultValue: """
                Too many actions are waiting (at most \(grouped(n))). Try again later.
                """,
            bundle: .module
        )
    }
    static func limitIntroductions(_ n: Int64) -> String {
        String(
            localized: "data_limit_introductions",
            defaultValue: """
                You have the most open introductions you can (\(grouped(n))).
                """,
            bundle: .module
        )
    }
    static func limitLocationShares(_ n: Int64) -> String {
        String(
            localized: "data_limit_location_shares",
            defaultValue: """
                You share your location with the most connections you can (\(grouped(n))).
                """,
            bundle: .module
        )
    }
    static var limitLocationRequests: String {
        String(
            localized: "data_limit_location_requests",
            defaultValue: """
                You asked this connection for their location a short while ago. Try again later.
                """,
            bundle: .module
        )
    }
    static func limitWallets(_ n: Int64) -> String {
        String(localized: "data_limit_wallets", defaultValue: "You have the most wallets you can (\(grouped(n))).", bundle: .module)
    }
    static func limitWalletAddresses(_ n: Int64) -> String {
        String(
            localized: "data_limit_wallet_addresses",
            defaultValue: """
                This wallet has the most addresses it can have (\(grouped(n))).
                """,
            bundle: .module
        )
    }
}
