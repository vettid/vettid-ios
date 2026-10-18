import Foundation
import Observation

/// A setup link the app was opened with (the account portal's same-device Universal Link,
/// `https://<account host>/vault/enroll/#s=<secret>`, VAULT-MESSAGING §11.12.1), handed from the scene to the
/// onboarding flow, which redeems it only while this phone has no vault. Observable: the onboarding flow follows
/// ``link``. The link carries the setup secret: never printed, dumped or mirrored. Mirrors vettid-android
/// `SetupLinkInbox`.
@MainActor
@Observable
public final class SetupLinkInbox: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public private(set) var link: String?

    public init() {}

    public func offer(_ raw: String) { link = raw }

    public func consume() { link = nil }

    public nonisolated var description: String { "SetupLinkInbox(…)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
}
