import Foundation
import Observation

/// An invitation link the app was opened with (VAULT-MESSAGING §6.4, 0.10.2): the Universal Link
/// `https://relay.vettid.org/connect#<link>` or the relay page's `vettid://connect#<link>` (IOS-PLAN §6.8), handed from
/// the scene to the connect flow once the vault is unlocked. Nothing is sent until the member confirms on the accept
/// screen; the payload inside decides the relay, never the URL's host. Observable: the connect flow follows ``link``.
/// The link lets whoever holds it ask to connect: never printed, dumped or mirrored. Mirrors vettid-android
/// `InviteLinkInbox`.
@MainActor
@Observable
public final class InviteLinkInbox: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public private(set) var link: String?

    public init() {}

    public func offer(_ raw: String) { link = raw }

    public func consume() { link = nil }

    public nonisolated var description: String { "InviteLinkInbox(…)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
}
