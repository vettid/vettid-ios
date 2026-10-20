import Foundation

/// The Messages screens' texts: vettid-android `feature/messages` `strings.xml`, word for word, under its string names
/// (the photo texts come with the photos, IOS-PLAN §8 I2.4). The link question is ANDROID-PLAN §4's "Open link to
/// <host>?"; vettid-android has no string for it yet, so its key and the "Open" button are chosen (not in the spec).
enum MessagesStrings {
    static var title: String { String(localized: "messages_title", defaultValue: "Messages", bundle: .module) }

    static var emptyTitle: String { String(localized: "messages_empty_title", defaultValue: "No messages", bundle: .module) }

    static var searchOpen: String { String(localized: "messages_search_open", defaultValue: "Search messages", bundle: .module) }

    static var search: String { String(localized: "messages_search", defaultValue: "Search by name or message", bundle: .module) }

    static var noMatchTitle: String {
        String(localized: "messages_no_match_title", defaultValue: "No conversations match", bundle: .module)
    }

    static var noMatchBody: String {
        String(localized: "messages_no_match_body", defaultValue: "Try another name or word", bundle: .module)
    }

    static var emptyBody: String {
        String(localized: "messages_empty_body", defaultValue: "Conversations with your connections appear here", bundle: .module)
    }

    static var emptyNoConnections: String {
        String(
            localized: "messages_empty_no_connections",
            defaultValue: "Invite someone to connect, then write to them here",
            bundle: .module
        )
    }

    static var emptyUnreadTitle: String {
        String(localized: "messages_empty_unread_title", defaultValue: "No unread messages", bundle: .module)
    }

    static var emptyUnreadBody: String {
        String(localized: "messages_empty_unread_body", defaultValue: "You are all caught up", bundle: .module)
    }

    static var filter: String { String(localized: "messages_filter", defaultValue: "Unread", bundle: .module) }

    static var add: String { String(localized: "messages_add", defaultValue: "New message", bundle: .module) }

    static var invite: String { String(localized: "messages_invite", defaultValue: "Invite a connection", bundle: .module) }

    static var nameNotShared: String {
        String(localized: "messages_name_not_shared", defaultValue: "Name not shared yet", bundle: .module)
    }

    static func previewYou(_ text: String) -> String {
        String(localized: "messages_preview_you", defaultValue: "You: \(text)", bundle: .module)
    }

    static var previewNone: String { String(localized: "messages_preview_none", defaultValue: "No messages yet", bundle: .module) }

    static func rowUnread(_ count: Int, _ preview: String) -> String {
        String(localized: "messages_row_unread", defaultValue: "\(count) unread · \(preview)", bundle: .module)
    }

    static var errorTitle: String { String(localized: "messages_error_title", defaultValue: "Could not load messages", bundle: .module) }

    static var retry: String { String(localized: "messages_retry", defaultValue: "Try again", bundle: .module) }

    static var ok: String { String(localized: "messages_ok", defaultValue: "OK", bundle: .module) }

    static var loadOlder: String { String(localized: "messages_load_older", defaultValue: "Show older messages", bundle: .module) }

    static var loadingOlder: String {
        String(localized: "messages_loading_older", defaultValue: "Loading older messages", bundle: .module)
    }

    static func details(_ name: String) -> String {
        String(localized: "messages_cd_details", defaultValue: "About \(name)", bundle: .module)
    }

    static var conversationEmptyTitle: String {
        String(localized: "messages_conversation_empty_title", defaultValue: "Say hello", bundle: .module)
    }

    static func conversationEmptyBody(_ name: String) -> String {
        String(
            localized: "messages_conversation_empty_body",
            defaultValue: "Messages with \(name) go through your vaults, end to end encrypted",
            bundle: .module
        )
    }

    static var statusSent: String { String(localized: "messages_status_sent", defaultValue: "Sent", bundle: .module) }

    static var statusDelivered: String { String(localized: "messages_status_delivered", defaultValue: "Delivered", bundle: .module) }

    static var statusRead: String { String(localized: "messages_status_read", defaultValue: "Read", bundle: .module) }

    static func outgoingLabel(_ text: String, _ time: String, _ status: String) -> String {
        String(localized: "messages_cd_outgoing", defaultValue: "You: \(text). \(time), \(status)", bundle: .module)
    }

    static func incomingLabel(_ name: String, _ text: String, _ time: String) -> String {
        String(localized: "messages_cd_incoming", defaultValue: "\(name): \(text). \(time)", bundle: .module)
    }

    static func replyHint(_ name: String) -> String {
        String(localized: "messages_reply_hint", defaultValue: "Message \(name)", bundle: .module)
    }

    static var tooLong: String {
        String(localized: "messages_too_long", defaultValue: "This message is too long (16 KB at most)", bundle: .module)
    }

    static var send: String { String(localized: "messages_send", defaultValue: "Send", bundle: .module) }

    static func inactive(_ name: String) -> String {
        String(
            localized: "messages_inactive",
            defaultValue: "\(name) cannot receive messages right now: the connection is not active.",
            bundle: .module
        )
    }

    static var deleteTitle: String { String(localized: "messages_delete_title", defaultValue: "Delete this message?", bundle: .module) }

    static func deleteBody(_ name: String) -> String {
        String(
            localized: "messages_delete_body",
            defaultValue: "It is removed from your vault only; \(name) keeps their copy.",
            bundle: .module
        )
    }

    static var deleteConfirm: String { String(localized: "messages_delete_confirm", defaultValue: "Delete", bundle: .module) }

    static var newTitle: String { String(localized: "messages_new_title", defaultValue: "New message", bundle: .module) }

    static var newEmptyTitle: String {
        String(localized: "messages_new_empty_title", defaultValue: "No connections yet", bundle: .module)
    }

    static func openLink(_ host: String) -> String {
        String(localized: "messages_open_link", defaultValue: "Open link to \(host)?", bundle: .module)
    }

    static var openLinkConfirm: String { String(localized: "messages_open_link_confirm", defaultValue: "Open", bundle: .module) }
}
