import Foundation
import VettIDAltChan
import VettIDData

/// Where a URL the app was opened with goes (IOS-PLAN §6.8): an invitation (`https://<relay>/connect#…`, the Universal
/// Link of `relay.vettid.org`, or `vettid://connect#…`) to ``InviteLinkInbox``, checked before the setup link as
/// vettid-android does; the portal's setup link to ``SetupLinkInbox``; anything else (a file) to the caller. A URL
/// longer than any VettID link is refused unread, as the scanner drops such texts (``QrTextGate/maxLength``). Nothing is
/// sent before the member confirms on the screen that takes it.
enum OpenedLink: Equatable {
    case invite(String)
    case setup(String)
    case other

    /// The longest URL taken (VettIDUI's `QrTextGate.maxLength`).
    static let maxLength = 4_096

    static func route(_ url: URL) -> OpenedLink {
        let s = url.absoluteString
        guard s.utf8.count <= maxLength else { return .other }
        if InviteLinks.isConnectURL(s) { return .invite(s) }
        if SetupCodes.isSetupLink(s) { return .setup(s) }
        return .other
    }
}
