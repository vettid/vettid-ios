import Foundation

/// What the accept screen opens with (vettid-android `AcceptRoute`'s arguments): [link] a scanned code (accepted at once)
/// or, with [opened], a link the app was opened with (the member confirms first); no link: the member pastes one. The
/// link lets whoever holds it ask to connect: never printed, dumped or mirrored (a navigation path holds this value).
public struct AcceptInput: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let link: String?
    public let opened: Bool

    public init(link: String? = nil, opened: Bool = false) {
        self.link = link
        self.opened = opened
    }

    public var description: String { "AcceptInput(link: \(link == nil ? "nil" : "…"), opened: \(opened))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The connect flow's screens, as the app shell pushes them (vettid-android `InviteRoute`, `ScanRoute`, `AcceptRoute`).
public enum ConnectDestination: Hashable, Sendable {
    case invite
    case scan
    case accept(AcceptInput)
}
