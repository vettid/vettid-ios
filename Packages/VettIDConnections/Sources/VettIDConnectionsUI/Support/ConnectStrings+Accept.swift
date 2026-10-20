import Foundation

/// The connect flow's texts of accepting an invitation and scanning one (vettid-android `feature/connections`
/// `strings.xml`, word for word, under its string names).
extension ConnectStrings {
    static var acceptTitle: String { String(localized: "connections_accept_title", defaultValue: "Paste an invitation", bundle: .module) }

    static var acceptBody: String {
        String(
            localized: "connections_accept_body",
            defaultValue: "Paste the link someone sent you. Your vault uses it to ask them to connect.",
            bundle: .module
        )
    }

    static var acceptField: String { String(localized: "connections_accept_field", defaultValue: "Invitation link", bundle: .module) }

    static var acceptConnect: String { String(localized: "connections_accept_connect", defaultValue: "Connect", bundle: .module) }

    static var acceptScanInstead: String {
        String(
            localized: "connections_accept_scan_instead",
            defaultValue: "Scan a QR code instead",
            bundle: .module
        )
    }

    static func waitingTitle(_ name: String) -> String {
        String(
            localized: "connections_waiting_title",
            defaultValue: "Contacting \(name)",
            bundle: .module
        )
    }

    static var waitingTitleUnnamed: String {
        String(
            localized: "connections_waiting_title_unnamed",
            defaultValue: "Contacting their vault",
            bundle: .module
        )
    }

    static var waitingBody: String {
        String(
            localized: "connections_waiting_body",
            defaultValue: """
                Your vault is setting up a secure session with theirs. A safety code appears here once it is done; you can \
                leave this screen and find the request under Approvals.
                """,
            bundle: .module
        )
    }

    static var waitingHandshake: String {
        String(
            localized: "connections_waiting_handshake",
            defaultValue: "Waiting for their vault…",
            bundle: .module
        )
    }

    static var compareTitle: String {
        String(
            localized: "connections_compare_title",
            defaultValue: "Compare the safety code",
            bundle: .module
        )
    }

    static var compareApprove: String {
        String(
            localized: "connections_compare_approve",
            defaultValue: "The codes match: approve",
            bundle: .module
        )
    }

    static var approvedTitle: String { String(localized: "connections_approved_title", defaultValue: "You approved", bundle: .module) }

    static func approvedBody(_ name: String) -> String {
        String(
            localized: "connections_approved_body",
            defaultValue: "The connection is made once \(name) approves too. You can leave this screen: it appears under Connections then.",
            bundle: .module
        )
    }

    static var existsTitle: String {
        String(
            localized: "connections_exists_title",
            defaultValue: "You're already connected",
            bundle: .module
        )
    }

    static func existsBody(_ name: String) -> String {
        String(
            localized: "connections_exists_body",
            defaultValue: """
                Your vault is already connected to \(name), or has asked to connect. This invitation was not used. If the \
                connection is broken, remove it and ask for a new invitation.
                """,
            bundle: .module
        )
    }

    static var existsOpen: String { String(localized: "connections_exists_open", defaultValue: "Open the connection", bundle: .module) }

    static var endedTitle: String { String(localized: "connections_ended_title", defaultValue: "No connection was made", bundle: .module) }

    static var endedDeclined: String {
        String(
            localized: "connections_ended_declined",
            defaultValue: "You declined the request.",
            bundle: .module
        )
    }

    static var endedExpired: String {
        String(
            localized: "connections_ended_expired",
            defaultValue: "The request expired before both of you approved.",
            bundle: .module
        )
    }

    static var endedFailed: String {
        String(
            localized: "connections_ended_failed",
            defaultValue: "The other vault did not complete the request in time, or the request was refused. Ask for a new invitation.",
            bundle: .module
        )
    }

    static func peerDeclinedOutgoing(_ name: String) -> String {
        String(
            localized: "connections_peer_declined_outgoing",
            defaultValue: "\(name) declined your connection request",
            bundle: .module
        )
    }

    static func peerDeclinedIncoming(_ name: String) -> String {
        String(
            localized: "connections_peer_declined_incoming",
            defaultValue: "\(name) declined the connection",
            bundle: .module
        )
    }

    static var peerDeclinedSomeone: String {
        String(
            localized: "connections_peer_declined_someone",
            defaultValue: "Someone",
            bundle: .module
        )
    }

    static var peerDeclinedBody: String {
        String(
            localized: "connections_peer_declined_body",
            defaultValue: "No connection was made.",
            bundle: .module
        )
    }

    static var openLinkTitle: String {
        String(
            localized: "connections_open_link_title",
            defaultValue: "Open an invitation",
            bundle: .module
        )
    }

    static var openLinkBody: String {
        String(
            localized: "connections_open_link_body",
            defaultValue: "You opened an invitation link. Connect only if you know who sent it; you compare a safety code with them next.",
            bundle: .module
        )
    }

    static var scanTitle: String { String(localized: "connections_scan_title", defaultValue: "Scan a QR code", bundle: .module) }

    static var scanBody: String {
        String(
            localized: "connections_scan_body",
            defaultValue: "Point the camera at the invitation code on their screen.",
            bundle: .module
        )
    }

    static var scanAllow: String { String(localized: "connections_scan_allow", defaultValue: "Allow camera", bundle: .module) }

    static var scanPasteInstead: String {
        String(
            localized: "connections_scan_paste_instead",
            defaultValue: "Paste a link instead",
            bundle: .module
        )
    }

    static var scanPermissionTitle: String {
        String(
            localized: "connections_scan_permission_title",
            defaultValue: "Camera access needed",
            bundle: .module
        )
    }

    static var scanPermissionBody: String {
        String(
            localized: "connections_scan_permission_body",
            defaultValue: "VettID uses the camera only to read the code; nothing is recorded or stored. You can paste a link instead.",
            bundle: .module
        )
    }
}
