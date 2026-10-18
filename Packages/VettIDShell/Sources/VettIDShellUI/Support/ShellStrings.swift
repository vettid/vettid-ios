import Foundation

// The package's texts, from `Resources/Localizable.xcstrings`. Keys are vettid-android's (the app's `strings.xml` and
// `strings_owner_check.xml`; the presence notice from `feature/onboarding`), the English values the same, word for word;
// `ios_` keys are the iPhone's own.

/// The shell's texts: the drawer, the avatar sheet, the owner check's banners.
enum ShellStrings {
    static var navMessages: String {
        String(localized: "nav_messages", defaultValue: "Messages", bundle: .module)
    }

    static var navConnections: String {
        String(localized: "nav_connections", defaultValue: "Connections", bundle: .module)
    }

    static var navApprovals: String {
        String(localized: "nav_approvals", defaultValue: "Approvals", bundle: .module)
    }

    static var navItems: String {
        String(localized: "nav_items", defaultValue: "Vault", bundle: .module)
    }

    static var navSettings: String {
        String(localized: "nav_settings", defaultValue: "Settings", bundle: .module)
    }

    static var navHelp: String {
        String(localized: "nav_help", defaultValue: "Help", bundle: .module)
    }

    static var navHistory: String {
        String(localized: "nav_history", defaultValue: "History", bundle: .module)
    }

    static func drawerVersion(_ a0: String, _ a1: Int) -> String {
        String(localized: "drawer_version", defaultValue: "VettID \(a0) (\(a1))", bundle: .module)
    }

    static var accountPlaceholderName: String {
        String(localized: "account_placeholder_name", defaultValue: "VettID member", bundle: .module)
    }

    static var accountEmail: String {
        String(localized: "account_email", defaultValue: "Email address", bundle: .module)
    }

    static var accountEmailNote: String {
        String(localized: "account_email_note", defaultValue: "Only you see this address.", bundle: .module)
    }

    static var accountOptions: String {
        String(localized: "account_options", defaultValue: "Options", bundle: .module)
    }

    static var accountNames: String {
        String(localized: "account_names", defaultValue: "VettID account name", bundle: .module)
    }

    static var accountNamesNote: String {
        String(localized: "account_names_note", defaultValue: "Your connections see this name", bundle: .module)
    }

    static var accountNamesNone: String {
        String(localized: "account_names_none", defaultValue: "Shown once your vault has heard from your account", bundle: .module)
    }

    static var accountChangeName: String {
        String(localized: "account_change_name", defaultValue: "Change name", bundle: .module)
    }

    static var accountChangeNameBody: String {
        String(localized: "account_change_name_body", defaultValue: "Only here, in the app, with your PIN and password", bundle: .module)
    }

    static var accountVaultStatus: String {
        String(localized: "account_vault_status", defaultValue: "Vault status", bundle: .module)
    }

    static var accountVaultStatusValue: String {
        String(localized: "account_vault_status_value", defaultValue: "Unlocked", bundle: .module)
    }

    static var accountLockVault: String {
        String(localized: "account_lock_vault", defaultValue: "Lock vault", bundle: .module)
    }

    static var accountLockVaultBody: String {
        String(
            localized: "account_lock_vault_body",
            defaultValue: "Locks your vault now. You need your PIN to open it again.",
            bundle: .module
        )
    }

    static var accountPortal: String {
        String(localized: "account_portal", defaultValue: "Open account portal", bundle: .module)
    }

    static var accountPortalBody: String {
        String(localized: "account_portal_body", defaultValue: "Membership, subscription and terms are changed there", bundle: .module)
    }

    static var accountMembership: String {
        String(localized: "account_membership", defaultValue: "Membership", bundle: .module)
    }

    static var accountMembershipMember: String {
        String(localized: "account_membership_member", defaultValue: "Member", bundle: .module)
    }

    static var accountMembershipRegistered: String {
        String(localized: "account_membership_registered", defaultValue: "Registered, not yet a member", bundle: .module)
    }

    static var accountMembershipCanceled: String {
        String(localized: "account_membership_canceled", defaultValue: "Account cancelled", bundle: .module)
    }

    static func accountMembershipCanceledUntil(_ s: String) -> String {
        String(
            localized: "account_membership_canceled_until",
            defaultValue: "Account cancelled: your vault is deleted on \(s)",
            bundle: .module
        )
    }

    static var accountMembershipUnknown: String {
        String(localized: "account_membership_unknown", defaultValue: "VettID account", bundle: .module)
    }

    static var accountMembershipWaiting: String {
        String(localized: "account_membership_waiting", defaultValue: "Shown once your vault has heard from your account", bundle: .module)
    }

    static var accountSubscription: String {
        String(localized: "account_subscription", defaultValue: "Subscription", bundle: .module)
    }

    static var accountSubscriptionNone: String {
        String(localized: "account_subscription_none", defaultValue: "No subscription", bundle: .module)
    }

    static var accountSubscriptionDefaultName: String {
        String(localized: "account_subscription_default_name", defaultValue: "Subscription", bundle: .module)
    }

    static func accountSubscriptionTrial(_ s: String) -> String {
        String(localized: "account_subscription_trial", defaultValue: "\(s): trial", bundle: .module)
    }

    static func accountSubscriptionTrialUntil(_ a0: String, _ a1: String) -> String {
        String(localized: "account_subscription_trial_until", defaultValue: "\(a0): trial until \(a1)", bundle: .module)
    }

    static func accountSubscriptionActive(_ s: String) -> String {
        String(localized: "account_subscription_active", defaultValue: "\(s): active", bundle: .module)
    }

    static func accountSubscriptionActiveUntil(_ a0: String, _ a1: String) -> String {
        String(localized: "account_subscription_active_until", defaultValue: "\(a0): active until \(a1)", bundle: .module)
    }

    static func accountSubscriptionExpired(_ s: String) -> String {
        String(localized: "account_subscription_expired", defaultValue: "\(s): expired", bundle: .module)
    }

    static func accountSubscriptionCanceled(_ s: String) -> String {
        String(localized: "account_subscription_canceled", defaultValue: "\(s): cancelled", bundle: .module)
    }

    static var accountTerms: String {
        String(localized: "account_terms", defaultValue: "Terms", bundle: .module)
    }

    static var accountTermsNeeded: String {
        String(
            localized: "account_terms_needed",
            defaultValue: "Updated terms are waiting: accept them on the account site",
            bundle: .module
        )
    }

    static var accountVoting: String {
        String(localized: "account_voting", defaultValue: "Voting rights", bundle: .module)
    }

    static var accountVotingYes: String {
        String(localized: "account_voting_yes", defaultValue: "Yes", bundle: .module)
    }

    static var accountVotingNo: String {
        String(localized: "account_voting_no", defaultValue: "No", bundle: .module)
    }

    static func ownerCheckWarning(_ s: String) -> String {
        String(localized: "owner_check_warning", defaultValue: "Your daily check is due at \(s).", bundle: .module)
    }

    static var ownerCheckWarningSoon: String {
        String(localized: "owner_check_warning_soon", defaultValue: "Your daily check is due within the hour.", bundle: .module)
    }

    static var ownerCheckNow: String {
        String(localized: "owner_check_now", defaultValue: "Check now", bundle: .module)
    }

    static var ownerCheckHoldOff: String {
        String(localized: "owner_check_hold_off", defaultValue: "The hold is off.", bundle: .module)
    }

    static func ownerCheckHoldOffUntil(_ s: String) -> String {
        String(localized: "owner_check_hold_off_until", defaultValue: "The hold is off until \(s).", bundle: .module)
    }

    static var ownerCheckHoldOn: String {
        String(localized: "owner_check_hold_on", defaultValue: "Turn on", bundle: .module)
    }

    static var ownerCheckNoticeOk: String {
        String(localized: "owner_check_notice_ok", defaultValue: "OK", bundle: .module)
    }

    static var ownerCheckNoticeLocked: String {
        String(localized: "owner_check_notice_locked", defaultValue: "Your vault locked after ten wrong daily checks.", bundle: .module)
    }

    static var ownerCheckNoticeFailedPin: String {
        String(localized: "owner_check_notice_failed_pin", defaultValue: "A daily check failed: wrong PIN.", bundle: .module)
    }

    static var ownerCheckNoticeFailedPassword: String {
        String(
            localized: "owner_check_notice_failed_password",
            defaultValue: "A daily check failed: wrong credential password.",
            bundle: .module
        )
    }

    static var ownerCheckNoticeHoldOff: String {
        String(localized: "owner_check_notice_hold_off", defaultValue: "The hold was turned off.", bundle: .module)
    }

    static func ownerCheckNoticeHoldOffUntil(_ s: String) -> String {
        String(localized: "owner_check_notice_hold_off_until", defaultValue: "The hold was turned off until \(s).", bundle: .module)
    }

    static var ownerCheckNoticeHoldOn: String {
        String(localized: "owner_check_notice_hold_on", defaultValue: "The hold was turned back on.", bundle: .module)
    }

    static var ownerCheckNoticeHoldExpired: String {
        String(localized: "owner_check_notice_hold_expired", defaultValue: "The hold is back on: its end date passed.", bundle: .module)
    }

    static func ownerCheckNoticeAt(_ a0: String, _ a1: String) -> String {
        String(localized: "owner_check_notice_at", defaultValue: "\(a0) (\(a1))", bundle: .module)
    }

    static func ownerCheckNoticeMore(_ a0: String, _ a1: Int) -> String {
        String(localized: "owner_check_notice_more", defaultValue: "\(a0) And \(a1) more.", bundle: .module)
    }

    static var ownercheckPresenceTitle: String {
        String(localized: "ownercheck_presence_title", defaultValue: "Your vault could not record that you were here.", bundle: .module)
    }

    static var ownercheckPresenceBody: String {
        String(
            localized: "ownercheck_presence_body",
            defaultValue: """
                If this stays for three days, your vault is no longer protected against a recovery started by someone \
                else. Try again later. If it does not go away, contact VettID.
                """,
            bundle: .module
        )
    }

    static var comingLater: String {
        String(
            localized: "ios_shell_coming_later",
            defaultValue: "This part of VettID is not in the iPhone app yet. It comes with a later update.",
            bundle: .module
        )
    }
}
