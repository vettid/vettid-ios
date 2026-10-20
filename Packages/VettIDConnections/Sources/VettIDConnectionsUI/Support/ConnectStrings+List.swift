import Foundation
import VettIDData

/// The Connections list's texts (vettid-android `feature/connections` `strings.xml`, word for word, under its string
/// names); the connection requests' own from vettid-android `feature/approvals`, under theirs.
extension ConnectStrings {
    static var title: String { String(localized: "connections_title", defaultValue: "Connections", bundle: .module) }

    static var searchOpen: String { String(localized: "connections_search_open", defaultValue: "Search connections", bundle: .module) }

    static var search: String { String(localized: "connections_search", defaultValue: "Search by name", bundle: .module) }

    static var noMatchTitle: String {
        String(localized: "connections_no_match_title", defaultValue: "No connections match", bundle: .module)
    }

    static var noMatchBody: String { String(localized: "connections_no_match_body", defaultValue: "Try another name", bundle: .module) }

    static var emptyTitle: String { String(localized: "connections_empty_title", defaultValue: "No connections yet", bundle: .module) }

    static var emptyBody: String {
        String(
            localized: "connections_empty_body",
            defaultValue: "Invite someone or scan their code to connect",
            bundle: .module
        )
    }

    static var errorTitle: String {
        String(localized: "connections_error_title", defaultValue: "Could not load connections", bundle: .module)
    }

    static var retry: String { String(localized: "connections_retry", defaultValue: "Try again", bundle: .module) }

    static var header: String { String(localized: "connections_header", defaultValue: "Connections", bundle: .module) }

    static var invitesHeader: String {
        String(localized: "connections_invites_header", defaultValue: "Open invitations", bundle: .module)
    }

    static var inviteInPerson: String {
        String(localized: "connections_invite_in_person", defaultValue: "In-person invitation", bundle: .module)
    }

    static var inviteRemote: String { String(localized: "connections_invite_remote", defaultValue: "Invitation link", bundle: .module) }

    static func inviteExpires(_ time: String) -> String {
        String(localized: "connections_invite_expires", defaultValue: "Expires \(time)", bundle: .module)
    }

    static var cancelInviteLabel: String {
        String(localized: "connections_cancel_invite_cd", defaultValue: "Cancel invitation", bundle: .module)
    }

    static var cancelInviteTitle: String {
        String(localized: "connections_cancel_invite_title", defaultValue: "Cancel this invitation?", bundle: .module)
    }

    static var cancelInviteBody: String {
        String(
            localized: "connections_cancel_invite_body",
            defaultValue: "Its QR code and link stop working at once. Anyone who has not used it yet cannot connect with it.",
            bundle: .module
        )
    }

    static var cancelInviteConfirm: String {
        String(localized: "connections_cancel_invite_confirm", defaultValue: "Cancel invitation", bundle: .module)
    }

    static var nameNotShared: String {
        String(localized: "connections_name_not_shared", defaultValue: "Name not shared yet", bundle: .module)
    }

    static var stateActive: String { String(localized: "connections_state_active", defaultValue: "Connected", bundle: .module) }

    static var statePending: String {
        String(localized: "connections_state_pending", defaultValue: "Waiting for approval", bundle: .module)
    }

    static var stateStale: String {
        String(localized: "connections_state_stale", defaultValue: "Out of reach: needs a new invitation", bundle: .module)
    }

    static var stateBlocked: String { String(localized: "connections_state_blocked", defaultValue: "Blocked", bundle: .module) }

    static var stateOther: String { String(localized: "connections_state_other", defaultValue: "Unavailable", bundle: .module) }

    /// A connection's state as a short label; nil for active (the usual case, left unsaid in rows).
    static func stateLabel(_ s: ConnectionState) -> String? {
        switch s {
        case .active: nil
        case .pending: statePending
        case .stale: stateStale
        case .blocked: stateBlocked
        case .other: stateOther
        }
    }

    // MARK: - Connection requests (vettid-android `feature/approvals`)

    static var typeConnection: String {
        String(localized: "approvals_type_connection", defaultValue: "Connection request", bundle: .module)
    }

    static var typeConnectionRemote: String {
        String(localized: "approvals_type_connection_remote", defaultValue: "Connection request (link)", bundle: .module)
    }

    static var typeOutgoing: String {
        String(localized: "approvals_type_outgoing", defaultValue: "Your connection request", bundle: .module)
    }

    static var goneTitle: String { String(localized: "approvals_gone_title", defaultValue: "Already decided", bundle: .module) }

    static var goneBody: String {
        String(
            localized: "approvals_gone_body",
            defaultValue: "This request was decided on another device, or it expired.",
            bundle: .module
        )
    }
}
