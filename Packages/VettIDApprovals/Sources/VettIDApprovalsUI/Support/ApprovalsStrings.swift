import Foundation

/// The Approvals screens' texts: vettid-android `feature/approvals` `strings.xml`, word for word, under its string names.
/// The list, the connection requests and member authentication here; grants, critical uses, shares, batches and devices
/// in ``ApprovalsStrings`` `+Asks`.
enum ApprovalsStrings {
    /// The bundle of these texts (the tests read every key from it).
    static var bundle: Bundle { .module }

    static var title: String { String(localized: "approvals_title", defaultValue: "Approvals", bundle: .module) }

    static var emptyTitle: String { String(localized: "approvals_empty_title", defaultValue: "Nothing to approve", bundle: .module) }

    static var emptyBody: String {
        String(
            localized: "approvals_empty_body",
            defaultValue: "Requests that need your decision appear here",
            bundle: .module
        )
    }

    static var errorTitle: String { String(localized: "approvals_error_title", defaultValue: "Could not load approvals", bundle: .module) }

    static var retry: String { String(localized: "approvals_retry", defaultValue: "Try again", bundle: .module) }

    static func peerDeclinedOutgoing(_ value: String) -> String {
        String(
            localized: "approvals_peer_declined_outgoing",
            defaultValue: "\(value) declined your connection request",
            bundle: .module
        )
    }

    static func peerDeclinedIncoming(_ value: String) -> String {
        String(
            localized: "approvals_peer_declined_incoming",
            defaultValue: "\(value) declined the connection",
            bundle: .module
        )
    }

    static var peerDeclinedSomeone: String {
        String(
            localized: "approvals_peer_declined_someone",
            defaultValue: "Someone",
            bundle: .module
        )
    }

    static var peerDeclinedBody: String {
        String(
            localized: "approvals_peer_declined_body",
            defaultValue: "No connection was made.",
            bundle: .module
        )
    }

    static var ok: String { String(localized: "approvals_ok", defaultValue: "OK", bundle: .module) }

    static var back: String { String(localized: "approvals_back", defaultValue: "Back", bundle: .module) }

    static var typeConnection: String {
        String(
            localized: "approvals_type_connection",
            defaultValue: "Connection request",
            bundle: .module
        )
    }

    static var typeConnectionRemote: String {
        String(
            localized: "approvals_type_connection_remote",
            defaultValue: "Connection request (link)",
            bundle: .module
        )
    }

    static var typeAuthentication: String {
        String(
            localized: "approvals_type_authentication",
            defaultValue: "Authenticate to a connection",
            bundle: .module
        )
    }

    static var typeGrant: String { String(localized: "approvals_type_grant", defaultValue: "Request to see your items", bundle: .module) }

    static var typeCritical: String {
        String(
            localized: "approvals_type_critical",
            defaultValue: "Use of a critical item",
            bundle: .module
        )
    }

    static var typeShare: String { String(localized: "approvals_type_share", defaultValue: "Share with a connection?", bundle: .module) }

    static var typeDevice: String { String(localized: "approvals_type_device", defaultValue: "Request from a device", bundle: .module) }

    static var typeSession: String { String(localized: "approvals_type_session", defaultValue: "Access session request", bundle: .module) }

    static var nameNotShared: String {
        String(
            localized: "approvals_name_not_shared",
            defaultValue: "Name not shared yet",
            bundle: .module
        )
    }

    static var aConnection: String { String(localized: "approvals_a_connection", defaultValue: "A connection", bundle: .module) }

    static var anAgent: String { String(localized: "approvals_an_agent", defaultValue: "An agent", bundle: .module) }

    static func summarySas(_ value: String) -> String {
        String(
            localized: "approvals_summary_sas",
            defaultValue: "code \(value)",
            bundle: .module
        )
    }

    static var typeOutgoing: String {
        String(
            localized: "approvals_type_outgoing",
            defaultValue: "Your connection request",
            bundle: .module
        )
    }

    static var summaryHandshake: String {
        String(
            localized: "approvals_summary_handshake",
            defaultValue: "waiting for their vault",
            bundle: .module
        )
    }

    static func summaryWaitingPeer(_ value: String) -> String {
        String(
            localized: "approvals_summary_waiting_peer",
            defaultValue: "code \(value) · waiting for them to approve",
            bundle: .module
        )
    }

    static func outgoingBody(_ value: String) -> String {
        String(
            localized: "approvals_outgoing_body",
            defaultValue: """
                You accepted \(value)'s invitation. Compare this code with \(value): it must match the code on their phone. Both of \
                you approve, then you are connected.
                """,
            bundle: .module
        )
    }

    static func outgoingBodyRemote(_ value: String) -> String {
        String(
            localized: "approvals_outgoing_body_remote",
            defaultValue: """
                You accepted \(value)'s invitation link. Compare this code with \(value) over a call or another channel you trust: \
                it must match the code on their phone.
                """,
            bundle: .module
        )
    }

    static var outgoingWaiting: String {
        String(
            localized: "approvals_outgoing_waiting",
            defaultValue: "Your vault is still setting up a secure session with theirs. The safety code appears here once it is done.",
            bundle: .module
        )
    }

    static var outgoingApprove: String {
        String(
            localized: "approvals_outgoing_approve",
            defaultValue: "The codes match: approve",
            bundle: .module
        )
    }

    static var outgoingName: String { String(localized: "approvals_outgoing_name", defaultValue: "Invitation from", bundle: .module) }

    static var them: String { String(localized: "approvals_them", defaultValue: "them", bundle: .module) }

    static var someone: String { String(localized: "approvals_someone", defaultValue: "Someone", bundle: .module) }

    static func waitingPeer(_ value: String) -> String {
        String(
            localized: "approvals_waiting_peer",
            defaultValue: "You approved. Waiting for \(value) to approve on their phone.",
            bundle: .module
        )
    }

    static var payloadLoading: String {
        String(
            localized: "approvals_payload_loading",
            defaultValue: "Fetching the data to sign…",
            bundle: .module
        )
    }

    static var payloadMismatchTitle: String {
        String(
            localized: "approvals_payload_mismatch_title",
            defaultValue: "This request cannot be shown",
            bundle: .module
        )
    }

    static var payloadMismatchBody: String {
        String(
            localized: "approvals_payload_mismatch_body",
            defaultValue: "The data to sign does not match the request's fingerprint, so it cannot be approved. Deny it.",
            bundle: .module
        )
    }

    static func summaryItems(_ count: Int) -> String {
        String(
            localized: "approvals_summary_items",
            defaultValue: "\(count) items",
            bundle: .module
        )
    }

    static var goneTitle: String { String(localized: "approvals_gone_title", defaultValue: "Already decided", bundle: .module) }

    static var goneBody: String {
        String(
            localized: "approvals_gone_body",
            defaultValue: "This request was decided on another device, or it expired.",
            bundle: .module
        )
    }

    // An approval not held on this phone that the vault never said was decided or expired (IOS-PLAN §6.9: one that
    // arrived only as an event is not read again after a lock or a restart). Text and keys chosen (chosen; not in the
    // spec), named for vettid-android to use the same.
    static var notHeldTitle: String {
        String(localized: "approvals_not_held_title", defaultValue: "No longer on this phone", bundle: .module)
    }

    static var notHeldBody: String {
        String(
            localized: "approvals_not_held_body",
            defaultValue: "This request is no longer shown on this phone. If it is still needed, it has to be asked for again.",
            bundle: .module
        )
    }

    static var deny: String { String(localized: "approvals_deny", defaultValue: "Deny", bundle: .module) }

    static var shareDecline: String { String(localized: "approvals_share_decline", defaultValue: "Do not share", bundle: .module) }

    static var password: String { String(localized: "approvals_password", defaultValue: "Credential password", bundle: .module) }

    static var passwordHint: String {
        String(
            localized: "approvals_password_hint",
            defaultValue: "This action uses your Protean Credential",
            bundle: .module
        )
    }

    static var block: String { String(localized: "approvals_block", defaultValue: "Block this request", bundle: .module) }

    static var blockTitle: String { String(localized: "approvals_block_title", defaultValue: "Block this request?", bundle: .module) }

    static var blockBody: String {
        String(
            localized: "approvals_block_body",
            defaultValue: "The request is declined and its vault cannot ask to connect again unless you unblock it.",
            bundle: .module
        )
    }

    static func connectionBody(_ value: String) -> String {
        String(
            localized: "approvals_connection_body",
            defaultValue: "\(value) used your invitation. Compare this code with \(value): it must match the code on their phone.",
            bundle: .module
        )
    }

    static func connectionBodyRemote(_ value: String) -> String {
        String(
            localized: "approvals_connection_body_remote",
            defaultValue: """
                \(value) used your invitation link. Anyone who saw the link could have used it: compare this code with \(value) \
                over a call or another channel you trust.
                """,
            bundle: .module
        )
    }

    static var connectionApprove: String {
        String(
            localized: "approvals_connection_approve",
            defaultValue: "The codes match: connect",
            bundle: .module
        )
    }

    static var nameGiven: String {
        String(
            localized: "approvals_name_given",
            defaultValue: "Name on their VettID account",
            bundle: .module
        )
    }

    static var namesNote: String {
        String(
            localized: "approvals_names_note",
            defaultValue: "The name they gave VettID for their account. VettID does not check it against any ID.",
            bundle: .module
        )
    }

    static func displayName(_ value: String) -> String {
        String(
            localized: "approvals_display_name",
            defaultValue: "Display name they chose: \(value)",
            bundle: .module
        )
    }

    static var selfAsserted: String {
        String(
            localized: "approvals_self_asserted",
            defaultValue: "They chose this themselves; VettID has not checked it.",
            bundle: .module
        )
    }

    static var introduced: String {
        String(
            localized: "approvals_introduced",
            defaultValue: "Introduced by one of your connections.",
            bundle: .module
        )
    }

    static var safetyCode: String { String(localized: "approvals_safety_code", defaultValue: "Safety code", bundle: .module) }

    static var sasHint: String {
        String(
            localized: "approvals_sas_hint",
            defaultValue: "Compare it with them. Approve only if the codes match.",
            bundle: .module
        )
    }

    static var sasHintRemote: String {
        String(
            localized: "approvals_sas_hint_remote",
            defaultValue: "Compare it with them over a call or another channel you trust. Approve only if the codes match.",
            bundle: .module
        )
    }

    static func expires(_ value: String) -> String {
        String(
            localized: "approvals_expires",
            defaultValue: "Expires \(value)",
            bundle: .module
        )
    }

    static func authBody(_ value: String) -> String {
        String(
            localized: "approvals_auth_body",
            defaultValue: "\(value) asks you to prove it is you. Approving signs their challenge with your credential key.",
            bundle: .module
        )
    }

    static var authApprove: String { String(localized: "approvals_auth_approve", defaultValue: "Authenticate", bundle: .module) }

    // A challenge with a purpose (VAULT-MESSAGING §10.4 "The screens per purpose", 0.65.0): the texts are the spec's, the
    // keys chosen (chosen; not in the spec), named for vettid-android to use the same.

    /// A `signin` challenge's title.
    static func authSigninTitle(_ value: String) -> String {
        String(localized: "approvals_auth_signin_title", defaultValue: "Sign in to \(value)?", bundle: .module)
    }

    static var authSigninBody: String {
        String(localized: "approvals_auth_signin_body", defaultValue: "Only approve if you are signing in right now.", bundle: .module)
    }

    /// A `signin` challenge's decline: it sends `connection.authenticate.deny`, as "Deny" does.
    static var authSigninDeny: String { String(localized: "approvals_auth_signin_deny", defaultValue: "Not me", bundle: .module) }

    /// An `approval` challenge's title.
    static func authApprovalTitle(_ value: String) -> String {
        String(localized: "approvals_auth_approval_title", defaultValue: "\(value) asks you to approve", bundle: .module)
    }

    /// The approve button of a challenge with a purpose.
    static var authPurposeApprove: String { String(localized: "approvals_auth_purpose_approve", defaultValue: "Approve", bundle: .module) }

    /// The requester inside a sentence when the connection has no name (chosen; not in the spec).
    static var aConnectionInline: String {
        String(localized: "approvals_a_connection_inline", defaultValue: "a connection", bundle: .module)
    }

    static var from: String { String(localized: "approvals_from", defaultValue: "From", bundle: .module) }

    static var context: String { String(localized: "approvals_context", defaultValue: "Their note", bundle: .module) }

    static func grantBody(_ value: String) -> String {
        String(
            localized: "approvals_grant_body",
            defaultValue: "\(value) asks to see items from your vault.",
            bundle: .module
        )
    }

    static var grantApprove: String { String(localized: "approvals_grant_approve", defaultValue: "Share these items", bundle: .module) }

    static var reason: String { String(localized: "approvals_reason", defaultValue: "Reason they gave", bundle: .module) }

    static var itemsAsked: String { String(localized: "approvals_items_asked", defaultValue: "Items", bundle: .module) }

    static func grantItem(_ value: String) -> String {
        String(
            localized: "approvals_grant_item",
            defaultValue: "\(value)",
            bundle: .module
        )
    }

    static func grantItemMissing(_ value: String) -> String {
        String(
            localized: "approvals_grant_item_missing",
            defaultValue: "\(value) (not in your vault)",
            bundle: .module
        )
    }

    static func grantCategory(_ value: String) -> String {
        String(
            localized: "approvals_grant_category",
            defaultValue: "Any \(value) item (you choose which)",
            bundle: .module
        )
    }

    static func grantUses(_ count: Int) -> String {
        String(
            localized: "approvals_grant_uses",
            defaultValue: "They can read it \(count) times.",
            bundle: .module
        )
    }
}
