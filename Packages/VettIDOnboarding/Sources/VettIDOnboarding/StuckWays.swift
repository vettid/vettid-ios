import Foundation
import Observation
import VettIDData

/// "Contact support" on a screen that cannot open the vault: an email to ``address`` with a fixed subject and nothing
/// else. No vault id, account data, logs or device details go into it. Mirrors vettid-android `SupportMail`.
public enum SupportMail {
    public static let address = "support@vettid.org"
    public static let subject = "VettID: help with my vault"

    /// The `mailto:` link: the address and the fixed subject only.
    public static var url: URL {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = address
        c.percentEncodedQuery = "subject=" + (subject.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        return c.url ?? URL(fileURLWithPath: "/")
    }
}

/// The confirmed way out of a dead end of the root screen (``AppPhase/unreachable(_:longUnreachable:)``). Mirrors
/// vettid-android `WayOut`.
public enum WayOut: Equatable, Sendable {
    /// The account service says the account has no vault: ask it once more, then forget this phone's keys for it.
    case startOver
    /// This phone's stored keys cannot be read: the in-app erase.
    case erase
    /// A wipe of this phone did not finish: "Erase VettID's data on this phone" (``AccountRepository/clearAppData()``).
    case clearData
    /// The account service no longer accepts this phone, or the vault has been unreachable for a long time: the in-app
    /// erase, with "Recover your vault" beside it.
    case eraseOrRecover

    public static func of(_ kind: FailureKind?, longUnreachable: Bool = false) -> WayOut? {
        switch kind {
        case .noVault: .startOver
        case .localState: .erase
        case .eraseFailed: .clearData
        case .unauthorized: .eraseOrRecover
        case .some(let k) where longUnreachable && k != .clock: .eraseOrRecover
        default: nil
        }
    }
}

/// The root screen of a phase that could not be read: "Try again", and the confirmed ways out. Mirrors the part of
/// vettid-android `RootViewModel` that serves `UnreachableScreen`.
@MainActor
@Observable
public final class UnreachableViewModel {
    /// A read of the phase is under way.
    public private(set) var retrying = false
    /// "Erase VettID's data on this phone" could not erase everything: the member is told to remove the app.
    public private(set) var clearDataFailed = false

    @ObservationIgnored private let account: any AccountRepository

    public init(account: any AccountRepository) {
        self.account = account
    }

    public func retry() {
        guard !retrying else { return }
        retrying = true
        Task { [weak self] in
            try? await self?.account.refresh()
            self?.retrying = false
        }
    }

    /// The way out the member confirmed, acted on only while the phase still offers it. Never without the confirmation.
    public func startOver(_ way: WayOut) {
        guard !retrying, case .unreachable(let kind, let long) = account.phase else { return }
        guard WayOut.of(kind, longUnreachable: long) == way else { return }
        retrying = true
        Task { [weak self, account] in
            do {
                switch way {
                case .startOver: try await account.forgetMissingVault()
                case .erase, .eraseOrRecover: try await account.eraseThisPhone()
                // Local only: nothing is sent, no session opens.
                case .clearData: if await !account.clearAppData() { self?.clearDataFailed = true }
                }
            } catch {
                try? await account.refresh()
            }
            self?.retrying = false
        }
    }
}
