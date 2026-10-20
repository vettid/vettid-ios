import Foundation

// The Approvals screens' texts for grants, critical uses, shares, batches, paused connections and devices: vettid-android
// `feature/approvals` `strings.xml`, word for word, under its string names.
extension ApprovalsStrings {
    static func criticalBody(_ value: String) -> String {
        String(
            localized: "approvals_critical_body",
            defaultValue: """
                \(value) asks your vault to use a critical item once. The value never leaves your vault; your password authorizes \
                exactly this use.
                """,
            bundle: .module
        )
    }

    static var criticalApprove: String {
        String(
            localized: "approvals_critical_approve",
            defaultValue: "Allow this one use",
            bundle: .module
        )
    }

    static var criticalItem: String { String(localized: "approvals_critical_item", defaultValue: "Item", bundle: .module) }

    static var criticalOperation: String { String(localized: "approvals_critical_operation", defaultValue: "Operation", bundle: .module) }

    static var criticalKind: String { String(localized: "approvals_critical_kind", defaultValue: "Field type", bundle: .module) }

    static var criticalSuitableNote: String {
        String(
            localized: "approvals_critical_suitable_note",
            defaultValue: """
                This works only if the field holds a signing key (an Ed25519 seed). If it holds something else, your vault tells \
                them it is unsuitable after your password.
                """,
            bundle: .module
        )
    }

    static var criticalUnsuitableTitle: String {
        String(
            localized: "approvals_critical_unsuitable_title",
            defaultValue: "This field cannot be used",
            bundle: .module
        )
    }

    static var criticalUnsuitableKind: String {
        String(
            localized: "approvals_critical_unsuitable_kind",
            defaultValue: "Only a password or text field can hold a signing key. Deny the request; nothing is used.",
            bundle: .module
        )
    }

    static func grantFields(_ value: String) -> String {
        String(
            localized: "approvals_grant_fields",
            defaultValue: "Fields: \(value)",
            bundle: .module
        )
    }

    static var kindPassword: String { String(localized: "approvals_kind_password", defaultValue: "Password", bundle: .module) }

    static var kindText: String { String(localized: "approvals_kind_text", defaultValue: "Text", bundle: .module) }

    static var kindMultiline: String { String(localized: "approvals_kind_multiline", defaultValue: "Long text", bundle: .module) }

    static var kindNumber: String { String(localized: "approvals_kind_number", defaultValue: "Number", bundle: .module) }

    static var kindDate: String { String(localized: "approvals_kind_date", defaultValue: "Date", bundle: .module) }

    static var kindEmail: String { String(localized: "approvals_kind_email", defaultValue: "Email", bundle: .module) }

    static var kindPhone: String { String(localized: "approvals_kind_phone", defaultValue: "Phone", bundle: .module) }

    static var kindUrl: String { String(localized: "approvals_kind_url", defaultValue: "Web address", bundle: .module) }

    static var kindOtp: String { String(localized: "approvals_kind_otp", defaultValue: "One-time code", bundle: .module) }

    static var kindAddress: String { String(localized: "approvals_kind_address", defaultValue: "Address", bundle: .module) }

    static var kindOther: String { String(localized: "approvals_kind_other", defaultValue: "Other", bundle: .module) }

    static var operationSign: String { String(localized: "approvals_operation_sign", defaultValue: "Sign their data", bundle: .module) }

    static var operationAuth: String {
        String(
            localized: "approvals_operation_auth",
            defaultValue: "Sign in (authenticate)",
            bundle: .module
        )
    }

    static var payload: String { String(localized: "approvals_payload", defaultValue: "Data to sign (base64)", bundle: .module) }

    static func shareBody(_ value: String) -> String {
        String(
            localized: "approvals_share_body",
            defaultValue: "A share rule asks whether to share these items with \(value).",
            bundle: .module
        )
    }

    static var shareApprove: String {
        String(
            localized: "approvals_share_approve",
            defaultValue: "Share the ticked items",
            bundle: .module
        )
    }

    static var shareTags: String { String(localized: "approvals_share_tags", defaultValue: "Because they carry", bundle: .module) }

    static var shareReasonRule: String {
        String(
            localized: "approvals_share_reason_rule",
            defaultValue: "You just made or changed this sharing rule.",
            bundle: .module
        )
    }

    static var shareReasonTagged: String {
        String(
            localized: "approvals_share_reason_tagged",
            defaultValue: "These items just gained one of the rule's tags.",
            bundle: .module
        )
    }

    static var shareItems: String { String(localized: "approvals_share_items", defaultValue: "Items", bundle: .module) }

    static var shareUnnamed: String { String(localized: "approvals_share_unnamed", defaultValue: "An item in your vault", bundle: .module) }

    static var shareUsable: String {
        String(
            localized: "approvals_share_usable",
            defaultValue: "Critical: they can ask to use it, never read it",
            bundle: .module
        )
    }

    static var shareNote: String {
        String(
            localized: "approvals_share_note",
            defaultValue: "Unticked items are not shared and you are not asked about them again unless their tags change.",
            bundle: .module
        )
    }

    static func shareAlsoAsks(_ value: String) -> String {
        String(
            localized: "approvals_share_also_asks",
            defaultValue: "Also covered by \(value), which asks you first",
            bundle: .module
        )
    }

    static func shareAlso(_ value: String) -> String {
        String(
            localized: "approvals_share_also",
            defaultValue: "Also covered by \(value)",
            bundle: .module
        )
    }

    static func shareAlready(_ value: String) -> String {
        String(
            localized: "approvals_share_already",
            defaultValue: "Already shared with \(value) by another rule. Not sharing it stops that sharing.",
            bundle: .module
        )
    }

    static func shareOneAnswer(_ value: String) -> String {
        String(
            localized: "approvals_share_one_answer",
            defaultValue: "Your answer counts for every rule for \(value) that covers the item.",
            bundle: .module
        )
    }

    static func ruleName(_ value: String) -> String {
        String(
            localized: "approvals_rule_name",
            defaultValue: "your “\(value)” rule",
            bundle: .module
        )
    }

    static func ruleNameAsks(_ value: String) -> String {
        String(
            localized: "approvals_rule_name_asks",
            defaultValue: "your “\(value)” rule (asks first)",
            bundle: .module
        )
    }

    static func ruleNameAuto(_ value: String) -> String {
        String(
            localized: "approvals_rule_name_auto",
            defaultValue: "your “\(value)” rule (shares automatically)",
            bundle: .module
        )
    }

    static func ruleNameUntil(_ a: String, _ b: String) -> String {
        String(
            localized: "approvals_rule_name_until",
            defaultValue: "your “\(a)” rule (until \(b))",
            bundle: .module
        )
    }

    static func ruleNameNoEnd(_ value: String) -> String {
        String(
            localized: "approvals_rule_name_no_end",
            defaultValue: "your “\(value)” rule (no end date)",
            bundle: .module
        )
    }

    static var anotherRule: String { String(localized: "approvals_another_rule", defaultValue: "another of your rules", bundle: .module) }

    static func batchTitle(_ name: String, _ count: Int) -> String {
        String(
            localized: "approvals_batch_title",
            defaultValue: "\(name) asks for \(count) things",
            bundle: .module
        )
    }

    static var batchShow: String { String(localized: "approvals_batch_show", defaultValue: "Show the requests", bundle: .module) }

    static var batchHide: String { String(localized: "approvals_batch_hide", defaultValue: "Hide the requests", bundle: .module) }

    static func pausedTitle(_ value: String) -> String {
        String(
            localized: "approvals_paused_title",
            defaultValue: "\(value)’s requests are paused",
            bundle: .module
        )
    }

    static var pausedTitleUnnamed: String {
        String(
            localized: "approvals_paused_title_unnamed",
            defaultValue: "A connection’s requests are paused",
            bundle: .module
        )
    }

    static var pausedBody: String {
        String(
            localized: "approvals_paused_body",
            defaultValue: "Paused after you declined several. Their requests are refused without asking you until you resume them.",
            bundle: .module
        )
    }

    static var pausedResume: String { String(localized: "approvals_paused_resume", defaultValue: "Resume requests", bundle: .module) }

    static var pausedRemove: String { String(localized: "approvals_paused_remove", defaultValue: "Remove connection", bundle: .module) }

    static func removeTitle(_ value: String) -> String {
        String(
            localized: "approvals_remove_title",
            defaultValue: "Remove \(value)?",
            bundle: .module
        )
    }

    static var removeBody: String {
        String(
            localized: "approvals_remove_body",
            defaultValue: "The connection ends and they are told it was removed. Connecting again needs a new invitation.",
            bundle: .module
        )
    }

    static var deviceBody: String {
        String(
            localized: "approvals_device_body",
            defaultValue: "A desktop or agent of yours asks for a decision.",
            bundle: .module
        )
    }

    static var device: String { String(localized: "approvals_device", defaultValue: "Device", bundle: .module) }

    static var request: String { String(localized: "approvals_request", defaultValue: "Request", bundle: .module) }

    static var deviceV1: String {
        String(
            localized: "approvals_device_v1",
            defaultValue: "This version of the app does not pair desktops or agents, so it can only decline.",
            bundle: .module
        )
    }

    static func grantTheirWords(_ value: String) -> String {
        String(
            localized: "approvals_grant_their_words",
            defaultValue: "They asked for: \(value)",
            bundle: .module
        )
    }

    static var grantAnswer: String {
        String(
            localized: "approvals_grant_answer",
            defaultValue: "Choose one of your items",
            bundle: .module
        )
    }

    static func grantAnswerChosen(_ value: String) -> String {
        String(
            localized: "approvals_grant_answer_chosen",
            defaultValue: "\(value) (change)",
            bundle: .module
        )
    }

    static var grantAnswerNone: String {
        String(
            localized: "approvals_grant_answer_none",
            defaultValue: "No standard or secret items in your vault",
            bundle: .module
        )
    }

    static var grantUsesLabel: String {
        String(
            localized: "approvals_grant_uses_label",
            defaultValue: "How many times they can fetch it",
            bundle: .module
        )
    }

    static var grantExpiryLabel: String { String(localized: "approvals_grant_expiry_label", defaultValue: "For how long", bundle: .module) }

    static func grantDays(_ count: Int) -> String {
        String(
            localized: "approvals_grant_days",
            defaultValue: "\(count) days",
            bundle: .module
        )
    }

    static var grantNote: String {
        String(
            localized: "approvals_grant_note",
            defaultValue: """
                They get the item's current values each time they fetch it, sealed to their phone. You can revoke it on their \
                Sharing screen. Critical items are never shared.
                """,
            bundle: .module
        )
    }

    static func backoff(_ count: Int) -> String {
        String(
            localized: "approvals_backoff",
            defaultValue: "Too many wrong passwords. Try again in \(count) s",
            bundle: .module
        )
    }

    static var backoffOver: String { String(localized: "approvals_backoff_over", defaultValue: "You can try again now", bundle: .module) }

    static var criticalDoneTitle: String { String(localized: "approvals_critical_done_title", defaultValue: "Done", bundle: .module) }

    static func criticalDoneBody(_ value: String) -> String {
        String(
            localized: "approvals_critical_done_body",
            defaultValue: "Your vault used the item once and sent \(value) only the result. Nothing else left your vault.",
            bundle: .module
        )
    }

    static var criticalFailedTitle: String {
        String(
            localized: "approvals_critical_failed_title",
            defaultValue: "Not used",
            bundle: .module
        )
    }

    static var criticalUnsuitable: String {
        String(
            localized: "approvals_critical_unsuitable",
            defaultValue: """
                This field cannot be used this way: it must hold an Ed25519 key (a base64 seed of 32 bytes). They were told it is \
                unsuitable.
                """,
            bundle: .module
        )
    }

    static var criticalUnavailable: String {
        String(
            localized: "approvals_critical_unavailable",
            defaultValue: "The item or field is no longer available to them. They were told.",
            bundle: .module
        )
    }
}
