import Foundation

/// A connection's detail and its asks card (vettid-android `feature/connections` `strings.xml`, word for word, under its
/// string names).
extension ConnectStrings {
    /// The pill's message action (shown once the messages are in the iPhone app, IOS-PLAN §8 I2.2).
    static func detailMessage(_ name: String) -> String {
        String(localized: "connections_detail_message", defaultValue: "Message \(name)", bundle: .module)
    }

    static var detailHistory: String { String(localized: "connections_detail_history", defaultValue: "History", bundle: .module) }

    static var detailProfile: String {
        String(localized: "connections_detail_profile", defaultValue: "Profile shared with you", bundle: .module)
    }

    static var detailProfileName: String {
        String(localized: "connections_detail_profile_name", defaultValue: "Display name", bundle: .module)
    }

    static var detailAccountName: String {
        String(localized: "connections_detail_account_name", defaultValue: "VettID account name", bundle: .module)
    }

    static var detailSharedItems: String {
        String(localized: "connections_detail_shared_items", defaultValue: "Items they share", bundle: .module)
    }

    static var detailProfileNone: String {
        String(
            localized: "connections_detail_profile_none",
            defaultValue: "Their vault has not sent its profile yet.",
            bundle: .module
        )
    }

    static var detailAbout: String { String(localized: "connections_detail_about", defaultValue: "About this connection", bundle: .module) }

    static var detailSince: String { String(localized: "connections_detail_since", defaultValue: "Connected", bundle: .module) }

    static var detailLastActive: String {
        String(localized: "connections_detail_last_active", defaultValue: "Last active", bundle: .module)
    }

    static var detailKey: String { String(localized: "connections_detail_key", defaultValue: "Vault key fingerprint", bundle: .module) }

    static var detailKeyNote: String {
        String(
            localized: "connections_detail_key_note",
            defaultValue: """
                Identifies their vault, the one you compared the safety code with, not a person. It changes only when their \
                vault rotates its key.
                """,
            bundle: .module
        )
    }

    static var remove: String { String(localized: "connections_remove", defaultValue: "Remove", bundle: .module) }

    static func removeTitle(_ name: String) -> String {
        String(localized: "connections_remove_title", defaultValue: "Remove \(name)?", bundle: .module)
    }

    static func removeBody(_ name: String) -> String {
        String(
            localized: "connections_remove_body",
            defaultValue: "The connection with \(name) ends and they are told it was removed. Connecting again needs a new invitation.",
            bundle: .module
        )
    }

    // MARK: - Asks (VAULT-MESSAGING 0.23.0 §10.4.1)

    static var theirsUnnamed: String { String(localized: "connections_share_theirs_unnamed", defaultValue: "Theirs", bundle: .module) }

    static func asksTitle(_ name: String) -> String {
        String(localized: "connections_asks_title", defaultValue: "Requests from \(name)", bundle: .module)
    }

    static var asksTitleUnnamed: String {
        String(localized: "connections_asks_title_unnamed", defaultValue: "Requests from this connection", bundle: .module)
    }

    static func asksNormal(_ name: String) -> String {
        String(
            localized: "connections_asks_normal",
            defaultValue: """
                \(name) can ask you for things: to see items, to use a critical item, to authenticate, to introduce someone \
                or for your location. You decide each time.
                """,
            bundle: .module
        )
    }

    static var asksPausedTitle: String {
        String(localized: "connections_asks_paused_title", defaultValue: "Requests paused", bundle: .module)
    }

    static func asksPaused(_ name: String) -> String {
        String(
            localized: "connections_asks_paused",
            defaultValue: """
                \(name)’s requests are paused after you declined several. They are refused without asking you until you \
                resume them.
                """,
            bundle: .module
        )
    }

    static func asksPausedSince(_ time: String) -> String {
        String(localized: "connections_asks_paused_since", defaultValue: "Paused \(time)", bundle: .module)
    }

    static var asksMutedTitle: String { String(localized: "connections_asks_muted_title", defaultValue: "Requests muted", bundle: .module) }

    static func asksMuted(_ name: String) -> String {
        String(
            localized: "connections_asks_muted",
            defaultValue: """
                You muted \(name)’s requests: they are refused without asking you. Messages, profile updates and sharing go \
                on.
                """,
            bundle: .module
        )
    }

    static func asksCooldowns(_ count: Int) -> String {
        String(
            localized: "connections_asks_cooldowns",
            defaultValue: "\(count) requests you declined are refused for 7 days.",
            bundle: .module
        )
    }

    static func asksNeutral(_ name: String) -> String {
        String(
            localized: "connections_asks_neutral",
            defaultValue: "\(name) is not told whether you declined, muted or paused: they only see that a request was not accepted.",
            bundle: .module
        )
    }

    static var asksMute: String { String(localized: "connections_asks_mute", defaultValue: "Mute requests", bundle: .module) }

    static var asksUnmute: String { String(localized: "connections_asks_unmute", defaultValue: "Unmute requests", bundle: .module) }

    static var asksResume: String { String(localized: "connections_asks_resume", defaultValue: "Resume requests", bundle: .module) }

    static var asksAllowAgain: String {
        String(localized: "connections_asks_allow_again", defaultValue: "Allow declined requests again", bundle: .module)
    }

    // ANDROID-PLAN 0.1.102 "Votes": approved by the owner 2026-10-30 (the same words as the Votes screens).
    static func voteRow(_ name: String) -> String {
        String(localized: "connections_vote_row", defaultValue: "Votes from \(name)", bundle: .module)
    }

    static func voteRemoveWarning(_ name: String) -> String {
        String(
            localized: "connections_vote_remove_warning",
            defaultValue: "You have a vote with \(name) that isn't finished. If you remove this connection you can't vote in it.",
            bundle: .module
        )
    }

    static var voteReconnectTitle: String {
        String(localized: "connections_vote_reconnect_title", defaultValue: "Connect again to vote", bundle: .module)
    }

    static func voteReconnectBody(_ name: String) -> String {
        String(
            localized: "connections_vote_reconnect_body",
            defaultValue: """
                \(name) is registered with VettID as a service. This connection was made before it said it was a service, \
                so it can't take part in votes. Remove it and connect again from a new invitation from \(name).
                """,
            bundle: .module
        )
    }
}
