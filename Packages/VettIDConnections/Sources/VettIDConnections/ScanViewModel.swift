import Foundation
import Observation
import VettIDData

/// The scanner's state: what the camera read that is not a usable invitation, or the invitation's link to accept. The
/// link lets whoever holds it ask to connect: never printed, dumped or mirrored. Mirrors vettid-android `ScanUiState`.
public struct ScanState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A code that is not a usable invitation: the scanner keeps looking and says why.
    public var problem: FailureKind?
    /// A connection invitation's link: the accept screen opens with it.
    public var link: String?

    public init(problem: FailureKind? = nil, link: String? = nil) {
        self.problem = problem
        self.link = link
    }

    public var description: String {
        "ScanState(problem: \(problem.map { "\($0)" } ?? "nil"), link: \(link == nil ? "nil" : "…"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The QR scanner (VAULT-MESSAGING §6.4): checks what the camera read (``InviteLinks``) before anything is sent to the
/// vault. Fed the decoded texts, so it works without a camera. Mirrors vettid-android `ScanViewModel`.
@MainActor
@Observable
public final class ScanViewModel {
    public private(set) var state = ScanState()
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public func onScanned(_ text: String) {
        guard state.link == nil else { return }
        switch InviteLinks.parse(text, now: now()) {
        case .ok(let link, _): state = ScanState(link: link)
        case .expired: state.problem = .inviteExpired
        case .notAConnection: state.problem = .inviteNotConnection
        case .invalid: state.problem = .inviteInvalid
        }
    }

    /// The accept screen took the link over.
    public func consumed() { state = ScanState() }
}
