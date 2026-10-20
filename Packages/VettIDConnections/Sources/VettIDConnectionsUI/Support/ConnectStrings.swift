import Foundation

/// The connect flow's texts: vettid-android `feature/connections` `strings.xml`, word for word, under its string names.
/// The add sheet, inviting and the request at the inviter here; accepting in ``ConnectStrings`` `+Accept`.
enum ConnectStrings {
    static var done: String { String(localized: "connections_done", defaultValue: "Done", bundle: .module) }

    static var ok: String { String(localized: "connections_ok", defaultValue: "OK", bundle: .module) }

    static var addInvite: String {
        String(
            localized: "connections_add_invite",
            defaultValue: "Invite with a QR code or link",
            bundle: .module
        )
    }

    static var addInviteBody: String {
        String(
            localized: "connections_add_invite_body",
            defaultValue: "Show your code in person, or send a link",
            bundle: .module
        )
    }

    static var addScan: String { String(localized: "connections_add_scan", defaultValue: "Scan a QR code", bundle: .module) }

    static var addScanBody: String {
        String(
            localized: "connections_add_scan_body",
            defaultValue: "Scan the code on their phone",
            bundle: .module
        )
    }

    static var addPaste: String { String(localized: "connections_add_paste", defaultValue: "Paste an invitation link", bundle: .module) }

    static var addPasteBody: String {
        String(
            localized: "connections_add_paste_body",
            defaultValue: "A link they sent you",
            bundle: .module
        )
    }

    static var inviteTitle: String { String(localized: "connections_invite_title", defaultValue: "Invite a connection", bundle: .module) }

    static var inviteBody: String {
        String(
            localized: "connections_invite_body",
            defaultValue: "Choose how long the invitation works. Each invitation connects one person, once.",
            bundle: .module
        )
    }

    static var inviteCreate: String { String(localized: "connections_invite_create", defaultValue: "Create invitation", bundle: .module) }

    static var ttl10m: String { String(localized: "connections_ttl_10m", defaultValue: "In person · 10 minutes", bundle: .module) }

    static var ttl1h: String { String(localized: "connections_ttl_1h", defaultValue: "Link · 1 hour", bundle: .module) }

    static var ttl24h: String { String(localized: "connections_ttl_24h", defaultValue: "Link · 24 hours", bundle: .module) }

    static var ttl7d: String { String(localized: "connections_ttl_7d", defaultValue: "Link · 7 days", bundle: .module) }

    static var ttlInPersonHint: String {
        String(
            localized: "connections_ttl_in_person_hint",
            defaultValue: "They scan the code on your screen",
            bundle: .module
        )
    }

    static var ttlRemoteHint: String {
        String(
            localized: "connections_ttl_remote_hint",
            defaultValue: "Send the link through another app",
            bundle: .module
        )
    }

    static var remoteTitle: String {
        String(
            localized: "connections_remote_title",
            defaultValue: "You approve every link connection",
            bundle: .module
        )
    }

    static var remoteBody: String {
        String(
            localized: "connections_remote_body",
            defaultValue: """
                Anyone who sees the link could use it, so the connection waits until you approve it. Compare the safety code \
                with them over a call you trust first.
                """,
            bundle: .module
        )
    }

    static var showTitle: String { String(localized: "connections_show_title", defaultValue: "Let them scan this code", bundle: .module) }

    static var showBody: String {
        String(
            localized: "connections_show_body",
            defaultValue: "Open VettID on their phone, tap Invite a connection on Connections, then Scan a QR code.",
            bundle: .module
        )
    }

    static var showRemoteTitle: String {
        String(
            localized: "connections_show_remote_title",
            defaultValue: "Send this link",
            bundle: .module
        )
    }

    static var showRemoteBody: String {
        String(
            localized: "connections_show_remote_body",
            defaultValue: "Send it through an app you trust. They paste it in VettID under Invite a connection on Connections.",
            bundle: .module
        )
    }

    static var qrLabel: String { String(localized: "connections_qr_cd", defaultValue: "Invitation QR code", bundle: .module) }

    static func expiresIn(_ minutes: Int, _ time: String) -> String {
        String(
            localized: "connections_expires_in",
            defaultValue: "Expires in \(minutes) min, at \(time)",
            bundle: .module
        )
    }

    static var linkLabel: String { String(localized: "connections_link_label", defaultValue: "Invitation link", bundle: .module) }

    static var copy: String { String(localized: "connections_copy", defaultValue: "Copy link", bundle: .module) }

    static var copied: String { String(localized: "connections_copied", defaultValue: "Copied", bundle: .module) }

    static var share: String { String(localized: "connections_share", defaultValue: "Share link", bundle: .module) }

    static var shareTitle: String { String(localized: "connections_share_title", defaultValue: "VettID invitation", bundle: .module) }

    static func shareText(_ url: String) -> String {
        String(
            localized: "connections_share_text",
            defaultValue: """
                Connect with me on VettID: open this link on a phone with VettID (or paste it under Invite a connection, Paste \
                an invitation link):\n\n\(url)
                """,
            bundle: .module
        )
    }

    static var waitingScan: String {
        String(
            localized: "connections_waiting_scan",
            defaultValue: "Waiting for them to use it…",
            bundle: .module
        )
    }

    static var inviteCancel: String { String(localized: "connections_invite_cancel", defaultValue: "Cancel invitation", bundle: .module) }

    static var inviteExpiredTitle: String {
        String(
            localized: "connections_invite_expired_title",
            defaultValue: "The invitation expired",
            bundle: .module
        )
    }

    static var inviteExpiredBody: String {
        String(
            localized: "connections_invite_expired_body",
            defaultValue: "Nobody used it in time. Create a new one when you are ready.",
            bundle: .module
        )
    }

    static var inviteAgain: String { String(localized: "connections_invite_again", defaultValue: "New invitation", bundle: .module) }

    static var requestTitle: String {
        String(
            localized: "connections_request_title",
            defaultValue: "Compare the safety code",
            bundle: .module
        )
    }

    static func requestBody(_ name: String) -> String {
        String(
            localized: "connections_request_body",
            defaultValue: "\(name) used your invitation. Compare this code with \(name): it must match the code on their phone.",
            bundle: .module
        )
    }

    static func requestBodyRemote(_ name: String) -> String {
        String(
            localized: "connections_request_body_remote",
            defaultValue: """
                \(name) used your invitation link. Anyone who saw the link could have used it: compare this code with \(name) \
                over a call or another channel you trust.
                """,
            bundle: .module
        )
    }

    static var requestSomeone: String { String(localized: "connections_request_someone", defaultValue: "Someone", bundle: .module) }

    static var requestThem: String { String(localized: "connections_request_them", defaultValue: "the other person", bundle: .module) }

    static var requestNameLabel: String {
        String(
            localized: "connections_request_name_label",
            defaultValue: "Name on their VettID account",
            bundle: .module
        )
    }

    static func requestDisplayName(_ name: String) -> String {
        String(
            localized: "connections_request_display_name",
            defaultValue: "Display name they chose: \(name)",
            bundle: .module
        )
    }

    static var namesNote: String {
        String(
            localized: "connections_names_note",
            defaultValue: "The name they gave VettID for their account. VettID does not check it against any ID.",
            bundle: .module
        )
    }

    static var requestNoName: String {
        String(
            localized: "connections_request_no_name",
            defaultValue: "Name not shared yet",
            bundle: .module
        )
    }

    static var selfAsserted: String {
        String(
            localized: "connections_self_asserted",
            defaultValue: "They chose this themselves; VettID has not checked it.",
            bundle: .module
        )
    }

    static var safetyCode: String { String(localized: "connections_safety_code", defaultValue: "Safety code", bundle: .module) }

    static var sasHint: String {
        String(
            localized: "connections_sas_hint",
            defaultValue: "Compare it with them now. Approve only if the codes match.",
            bundle: .module
        )
    }

    static var sasHintRemote: String {
        String(
            localized: "connections_sas_hint_remote",
            defaultValue: "Compare it with them over a call or another channel you trust. Approve only if the codes match.",
            bundle: .module
        )
    }

    static func sasHintInvitee(_ name: String) -> String {
        String(
            localized: "connections_sas_hint_invitee",
            defaultValue: "Compare it with \(name): it must match the code on their phone. Both of you approve, then you are connected.",
            bundle: .module
        )
    }

    static func sasHintInviteeRemote(_ name: String) -> String {
        String(
            localized: "connections_sas_hint_invitee_remote",
            defaultValue: """
                Compare it with \(name) over a call or another channel you trust: it must match the code on their phone. Both \
                of you approve, then you are connected.
                """,
            bundle: .module
        )
    }

    static func waitingPeer(_ name: String) -> String {
        String(
            localized: "connections_waiting_peer",
            defaultValue: "Waiting for \(name) to approve on their phone…",
            bundle: .module
        )
    }

    static var autoApprovedTitle: String {
        String(
            localized: "connections_auto_approved_title",
            defaultValue: "Approved automatically",
            bundle: .module
        )
    }

    static func autoApproved(_ name: String) -> String {
        String(
            localized: "connections_auto_approved",
            defaultValue: """
                Your vault approved this in-person request for you. Compare the code with \(name); decline if it does not \
                match.
                """,
            bundle: .module
        )
    }

    static var requestApprove: String {
        String(
            localized: "connections_request_approve",
            defaultValue: "The codes match: connect",
            bundle: .module
        )
    }

    static var requestDecline: String { String(localized: "connections_request_decline", defaultValue: "Decline", bundle: .module) }

    static var blockRequest: String { String(localized: "connections_block_request", defaultValue: "Block this request", bundle: .module) }

    static var blockRequestTitle: String {
        String(
            localized: "connections_block_request_title",
            defaultValue: "Block this request?",
            bundle: .module
        )
    }

    static var blockRequestBody: String {
        String(
            localized: "connections_block_request_body",
            defaultValue: "The request is declined and its vault cannot ask to connect again unless you unblock it.",
            bundle: .module
        )
    }

    static var block: String { String(localized: "connections_block", defaultValue: "Block", bundle: .module) }

    static var connectedTitle: String {
        String(
            localized: "connections_connected_title",
            defaultValue: "You are connected",
            bundle: .module
        )
    }

    static func connectedBody(_ name: String) -> String {
        String(
            localized: "connections_connected_body",
            defaultValue: "You and \(name) can now message each other through your vaults.",
            bundle: .module
        )
    }

    static var connectedBodyUnnamed: String {
        String(
            localized: "connections_connected_body_unnamed",
            defaultValue: "You can now message each other through your vaults.",
            bundle: .module
        )
    }

    static var sendMessage: String { String(localized: "connections_send_message", defaultValue: "Send a message", bundle: .module) }
}
