import Foundation

// The feed's texts (ANDROID-PLAN §4 Notifications, 4): vettid-android `core/data` `strings.xml`, word for word, under its
// string names. The kinds of VAULT-MESSAGING §10.9 up to release R here; release R's event titles (IOS-PLAN §4.1) in
// ``DataStrings`` `+FeedEvents`.
extension DataStrings {
    static var feedSomeone: String { String(localized: "data_feed_someone", defaultValue: "Someone", bundle: .module) }

    static var feedRemovedConnection: String {
        String(
            localized: "data_feed_removed_connection",
            defaultValue: "Removed connection",
            bundle: .module
        )
    }

    static var feedNameNotShared: String { String(localized: "data_feed_name_not_shared", defaultValue: "A connection", bundle: .module) }

    static var feedDeletedItem: String { String(localized: "data_feed_deleted_item", defaultValue: "Deleted item", bundle: .module) }

    static func feedConnectionRequest(_ value: String) -> String {
        String(
            localized: "data_feed_connection_request",
            defaultValue: "\(value) wants to connect",
            bundle: .module
        )
    }

    static func feedConnectionPeerDeclined(_ value: String) -> String {
        String(
            localized: "data_feed_connection_peer_declined",
            defaultValue: "\(value) did not accept your request",
            bundle: .module
        )
    }

    static func feedConnectionAdded(_ value: String) -> String {
        String(
            localized: "data_feed_connection_added",
            defaultValue: "You are now connected with \(value)",
            bundle: .module
        )
    }

    static func feedConnectionRemoved(_ value: String) -> String {
        String(
            localized: "data_feed_connection_removed",
            defaultValue: "\(value) was removed",
            bundle: .module
        )
    }

    static func feedConnectionStale(_ value: String) -> String {
        String(
            localized: "data_feed_connection_stale",
            defaultValue: "\(value) has not been reachable",
            bundle: .module
        )
    }

    static func feedAsksPaused(_ value: String) -> String {
        String(
            localized: "data_feed_asks_paused",
            defaultValue: "\(value)’s requests are paused",
            bundle: .module
        )
    }

    static func feedAuthenticate(_ value: String) -> String {
        String(
            localized: "data_feed_authenticate",
            defaultValue: "\(value) asks you to confirm it is you",
            bundle: .module
        )
    }

    // A challenge with a purpose (VAULT-MESSAGING §10.4 "The screens per purpose", 0.65.0): the texts are the spec's, the
    // keys chosen (chosen; not in the spec), named for vettid-android to use the same.

    static func feedAuthenticateSignin(_ value: String) -> String {
        String(localized: "data_feed_authenticate_signin", defaultValue: "Sign in to \(value)?", bundle: .module)
    }

    static var feedAuthenticateSigninBody: String {
        String(
            localized: "data_feed_authenticate_signin_body",
            defaultValue: "Only approve if you are signing in right now.",
            bundle: .module
        )
    }

    static func feedAuthenticateApproval(_ value: String) -> String {
        String(localized: "data_feed_authenticate_approval", defaultValue: "\(value) asks you to approve", bundle: .module)
    }

    /// The requester inside a sign-in's title when no name is known.
    static var feedAConnectionInline: String {
        String(localized: "data_feed_a_connection_inline", defaultValue: "a connection", bundle: .module)
    }

    static func feedMessage(_ value: String) -> String {
        String(
            localized: "data_feed_message",
            defaultValue: "New message from \(value)",
            bundle: .module
        )
    }

    static func feedCallMissed(_ value: String) -> String {
        String(
            localized: "data_feed_call_missed",
            defaultValue: "Missed call from \(value)",
            bundle: .module
        )
    }

    static func feedPhotoFailed(_ value: String) -> String {
        String(
            localized: "data_feed_photo_failed",
            defaultValue: "Photo to \(value) not delivered",
            bundle: .module
        )
    }

    static func feedPhotoRefused(_ value: String) -> String {
        String(
            localized: "data_feed_photo_refused",
            defaultValue: "Photo from \(value) refused: your vault is full",
            bundle: .module
        )
    }

    static func feedGrantRequest(_ a: String, _ b: String) -> String {
        String(
            localized: "data_feed_grant_request",
            defaultValue: "\(a) asks for \(b)",
            bundle: .module
        )
    }

    static func feedGrantRequestAny(_ value: String) -> String {
        String(
            localized: "data_feed_grant_request_any",
            defaultValue: "\(value) asks for an item",
            bundle: .module
        )
    }

    static func feedGrantRequestBatch(_ name: String, _ count: Int) -> String {
        String(
            localized: "data_feed_grant_request_batch",
            defaultValue: "\(name) asks for \(count) things",
            bundle: .module
        )
    }

    static func feedThings(_ count: Int) -> String {
        String(
            localized: "data_feed_things",
            defaultValue: "\(count) things",
            bundle: .module
        )
    }

    static func feedGrantShared(_ value: String) -> String {
        String(
            localized: "data_feed_grant_shared",
            defaultValue: "\(value) shared an item with you",
            bundle: .module
        )
    }

    static func feedGrantRevoked(_ value: String) -> String {
        String(
            localized: "data_feed_grant_revoked",
            defaultValue: "\(value) stopped sharing an item",
            bundle: .module
        )
    }

    static func feedSharePending(_ a: String, _ b: String) -> String {
        String(
            localized: "data_feed_share_pending",
            defaultValue: "Your \(a) rule for \(b) needs a decision",
            bundle: .module
        )
    }

    static func feedSharePendingAny(_ value: String) -> String {
        String(
            localized: "data_feed_share_pending_any",
            defaultValue: "A share rule for \(value) needs a decision",
            bundle: .module
        )
    }

    static func feedShareRateLimited(_ value: String) -> String {
        String(
            localized: "data_feed_share_rate_limited",
            defaultValue: "\(value) reached the limit of a share rule",
            bundle: .module
        )
    }

    static func feedCriticalUse(_ a: String, _ b: String) -> String {
        String(
            localized: "data_feed_critical_use",
            defaultValue: "\(a) asks to use \(b)",
            bundle: .module
        )
    }

    static func feedCriticalUseAny(_ value: String) -> String {
        String(
            localized: "data_feed_critical_use_any",
            defaultValue: "\(value) asks to use a critical item",
            bundle: .module
        )
    }

    static func feedItemRevealed(_ value: String) -> String {
        String(
            localized: "data_feed_item_revealed",
            defaultValue: "\(value) was revealed",
            bundle: .module
        )
    }

    static var feedItemRevealedAny: String {
        String(
            localized: "data_feed_item_revealed_any",
            defaultValue: "A critical item was revealed",
            bundle: .module
        )
    }

    static var feedDevicePairPending: String {
        String(
            localized: "data_feed_device_pair_pending",
            defaultValue: "A device asks to pair",
            bundle: .module
        )
    }

    static var feedDevicePaired: String {
        String(
            localized: "data_feed_device_paired",
            defaultValue: "A device was paired",
            bundle: .module
        )
    }

    static var feedDeviceUnlinked: String {
        String(
            localized: "data_feed_device_unlinked",
            defaultValue: "A device was removed",
            bundle: .module
        )
    }

    static var feedDeviceTransferred: String {
        String(
            localized: "data_feed_device_transferred",
            defaultValue: "Your vault moved to this phone",
            bundle: .module
        )
    }

    /// "Your vault moved to a new phone": the feed's `device.replaced`, and the one title of every text that another phone
    /// holds the vault's credential (``FailureKind/notHolderTitle``): the title above the body `vault_not_holder`, and
    /// the title of a change's one-time notice.
    static var feedDeviceReplaced: String {
        String(
            localized: "data_feed_device_replaced",
            defaultValue: "Your vault moved to a new phone",
            bundle: .module
        )
    }

    static var feedDeviceSignerChanged: String {
        String(
            localized: "data_feed_device_signer_changed",
            defaultValue: "Your vault moved to another version of VettID",
            bundle: .module
        )
    }

    static func feedSignerFromTo(_ a: String, _ b: String) -> String {
        String(
            localized: "data_feed_signer_from_to",
            defaultValue: "From \(a) to \(b)",
            bundle: .module
        )
    }

    static var signerGooglePlay: String {
        String(
            localized: "data_signer_google_play",
            defaultValue: "Google Play (signed by Google)",
            bundle: .module
        )
    }

    static var signerVettid: String {
        String(
            localized: "data_signer_vettid",
            defaultValue: "F-Droid or direct (signed by VettID)",
            bundle: .module
        )
    }

    static var signerDevelopment: String {
        String(
            localized: "data_signer_development",
            defaultValue: "a development build",
            bundle: .module
        )
    }

    static var signerOther: String { String(localized: "data_signer_other", defaultValue: "another signer", bundle: .module) }

    static var feedDeviceSession: String {
        String(
            localized: "data_feed_device_session",
            defaultValue: "A device asks for access",
            bundle: .module
        )
    }

    static var feedDeviceApproval: String {
        String(
            localized: "data_feed_device_approval",
            defaultValue: "A device asks to approve a request",
            bundle: .module
        )
    }

    static var feedCredentialAlarm: String {
        String(
            localized: "data_feed_credential_alarm",
            defaultValue: "Your credential was used somewhere else",
            bundle: .module
        )
    }

    static var feedPasswordFailed: String {
        String(
            localized: "data_feed_password_failed",
            defaultValue: "Wrong credential password entered",
            bundle: .module
        )
    }

    static var feedCredentialRotated: String {
        String(
            localized: "data_feed_credential_rotated",
            defaultValue: "Your credential was renewed",
            bundle: .module
        )
    }

    static var feedCredentialReset: String {
        String(
            localized: "data_feed_credential_reset",
            defaultValue: "Your credential was reset",
            bundle: .module
        )
    }

    static var feedCheckFailed: String {
        String(
            localized: "data_feed_check_failed",
            defaultValue: "A daily check failed",
            bundle: .module
        )
    }

    static var feedCheckFailedPin: String {
        String(
            localized: "data_feed_check_failed_pin",
            defaultValue: "A daily check failed: wrong PIN",
            bundle: .module
        )
    }

    static var feedCheckFailedPassword: String {
        String(
            localized: "data_feed_check_failed_password",
            defaultValue: "A daily check failed: wrong password",
            bundle: .module
        )
    }

    static var feedCheckLocked: String {
        String(
            localized: "data_feed_check_locked",
            defaultValue: "Your vault locked after 10 failed checks",
            bundle: .module
        )
    }

    static func feedHoldOffUntil(_ value: String) -> String {
        String(
            localized: "data_feed_hold_off_until",
            defaultValue: "Hold turned off until \(value)",
            bundle: .module
        )
    }

    static var feedHoldOff: String { String(localized: "data_feed_hold_off", defaultValue: "Hold turned off", bundle: .module) }

    static var feedHoldOn: String { String(localized: "data_feed_hold_on", defaultValue: "Hold turned on", bundle: .module) }

    static var feedHoldBackOn: String { String(localized: "data_feed_hold_back_on", defaultValue: "Hold back on", bundle: .module) }

    static var feedGuide: String { String(localized: "data_feed_guide", defaultValue: "A tip from VettID", bundle: .module) }

    static var feedLeash: String { String(localized: "data_feed_leash", defaultValue: "Agent activity", bundle: .module) }

    static var feedLeashRateLimited: String {
        String(
            localized: "data_feed_leash_rate_limited",
            defaultValue: "An agent reached its limit",
            bundle: .module
        )
    }

    static var feedLeashItemRead: String {
        String(
            localized: "data_feed_leash_item_read",
            defaultValue: "An agent read an item",
            bundle: .module
        )
    }

    static var feedLeashSuspended: String {
        String(
            localized: "data_feed_leash_suspended",
            defaultValue: "An agent was suspended",
            bundle: .module
        )
    }

    static var feedLeashReferrals: String {
        String(
            localized: "data_feed_leash_referrals",
            defaultValue: "An agent’s referrals were limited",
            bundle: .module
        )
    }

    static func feedActionRequest(_ value: String) -> String {
        String(
            localized: "data_feed_action_request",
            defaultValue: "\(value) asks you to run an action",
            bundle: .module
        )
    }

    static func feedIntroRequest(_ value: String) -> String {
        String(
            localized: "data_feed_intro_request",
            defaultValue: "\(value) wants to introduce someone",
            bundle: .module
        )
    }

    static func feedLocationShared(_ value: String) -> String {
        String(
            localized: "data_feed_location_shared",
            defaultValue: "\(value) shared a location",
            bundle: .module
        )
    }

    static func feedLocationRequest(_ value: String) -> String {
        String(
            localized: "data_feed_location_request",
            defaultValue: "\(value) asks for your location",
            bundle: .module
        )
    }

    static var feedWalletSigned: String {
        String(
            localized: "data_feed_wallet_signed",
            defaultValue: "A wallet transaction was signed",
            bundle: .module
        )
    }

    // ANDROID-PLAN 0.1.102 "Votes": titles and second lines approved by the owner 2026-10-30.
    static var feedVoteOpen: String {
        String(localized: "data_feed_vote_open", defaultValue: "A new vote", bundle: .module)
    }

    static var feedVoteClosing: String {
        String(localized: "data_feed_vote_closing", defaultValue: "A vote closes soon", bundle: .module)
    }

    static var feedVoteResult: String {
        String(localized: "data_feed_vote_result", defaultValue: "Vote results are out", bundle: .module)
    }

    static var feedVoteProblem: String {
        String(localized: "data_feed_vote_problem", defaultValue: "Check your vote", bundle: .module)
    }

    static var feedVoteProblemBody: String {
        String(localized: "data_feed_vote_problem_body", defaultValue: "Something about your vote needs your attention.", bundle: .module)
    }

    static func feedVoteLine(_ service: String, _ title: String) -> String {
        String(localized: "data_feed_vote_line", defaultValue: "\(service): \(title)", bundle: .module)
    }
}
