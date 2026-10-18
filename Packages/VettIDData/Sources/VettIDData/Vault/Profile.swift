import Foundation
import Observation
import VettIDVault

/// What `account.name.set` came to (VAULT-MESSAGING §10.8). Mirrors vettid-android `NameChangeOutcome`.
public enum NameChangeOutcome: Equatable, Sendable {
    /// Stored by the vault and handed to VettID: the request (normally `pending`).
    case requested(NameRequestView)
    /// At most one applied change per 30 days: [allowedAfter] (nil when the vault did not say).
    case tooSoon(allowedAfter: Date?)
    /// The names break the registration rule, or equal the current ones (`bad_request`).
    case invalid
    /// The PIN was wrong: a failed owner check (§3.6.4); [checksLeft] before the vault locks, when known.
    case badPin(checksLeft: Int?)
    case badPassword(checksLeft: Int?)
    /// A PIN or password backoff runs ([retryAfterSeconds] 0 when the vault did not say how long).
    case backoff(retryAfterSeconds: Int64)
    case failed(FailureKind, code: String?)
}

/// The member's shared profile and the account's names (VAULT-MESSAGING §10.8). The iPhone app has the name change so
/// far; the shared profile (`profile.get`, `profile.set`, the photo) comes with IOS-PLAN §8 I2.5. Failures other than a
/// ``NameChangeOutcome`` are ``VaultFailure``s. Mirrors vettid-android `ProfileRepository`.
@MainActor
public protocol ProfileRepository: AnyObject, Sendable {
    /// `account.name.set` with the PIN, the credential password and the two names, which the caller has checked with
    /// ``AccountNames/check(_:)`` (they are sent normalised). The account's names change only once VettID applied the
    /// request; the outcome arrives in the account (``AccountInfo/nameRequest``).
    func changeName(pin: String, password: String, firstName: String, lastName: String) async -> NameChangeOutcome
}

/// The vault calls behind ``ProfileManager``. Mirrors vettid-android `ProfileOps` (the name change so far).
public protocol ProfileOps: Sendable {
    func accountNameSet(pin: String, password: String, firstName: String, lastName: String) async throws -> NameRequest
}

/// ``ProfileRepository`` over ``ProfileOps``. [onRequest] keeps a new name request with the account, with the [mark]
/// read before the request was sent (the account record it belongs to); [checksLeft] re-reads the owner check's count
/// after a failed PIN or password (§3.6.4: a name change counts as a check). Mirrors vettid-android `ProfileManager`.
@MainActor
public final class ProfileManager: ProfileRepository {
    private let ops: @MainActor () async throws -> any ProfileOps
    private let onRequest: @MainActor (NameRequestView, _ mark: Int) -> Void
    private let checksLeft: @MainActor () async -> Int?
    private let mark: @MainActor () -> Int

    public init(
        ops: @escaping @MainActor () async throws -> any ProfileOps,
        onRequest: @escaping @MainActor (NameRequestView, _ mark: Int) -> Void,
        checksLeft: @escaping @MainActor () async -> Int?,
        mark: @escaping @MainActor () -> Int = { 0 }
    ) {
        self.ops = ops
        self.onRequest = onRequest
        self.checksLeft = checksLeft
        self.mark = mark
    }

    public func changeName(pin: String, password: String, firstName: String, lastName: String) async -> NameChangeOutcome {
        guard let first = AccountNames.normalize(firstName), let last = AccountNames.normalize(lastName) else { return .invalid }
        let since = mark()
        do {
            let r = try await ops().accountNameSet(pin: pin, password: password, firstName: first, lastName: last)
            let view = NameRequestView.of(r)
                ?? NameRequestView(seq: r.seq, firstName: first, lastName: last, requestedAt: nil, state: .pending)
            onRequest(view, since)
            return .requested(view)
        } catch {
            let f = VaultFailures.map(error) as? VaultFailure ?? VaultFailure(.other)
            return await failed(f)
        }
    }

    private func failed(_ e: VaultFailure) async -> NameChangeOutcome {
        switch e.code {
        case Self.codeTooSoon:
            let after = ((e.cause as? VaultOpError)?.body).flatMap { VaultJSON.string(VaultJSON.object($0), "allowed_after") }
            return .tooSoon(allowedAfter: OwnerCheckManager.instant(after))
        case Self.codeBadRequest: return .invalid
        case Self.codeBadPin: return .badPin(checksLeft: await checksLeft())
        case Self.codeBadPassword: return .badPassword(checksLeft: await checksLeft())
        case Self.codeBackoff: return .backoff(retryAfterSeconds: e.retryAfterSeconds)
        default: return .failed(e.kind, code: e.code)
        }
    }

    static let codeTooSoon = "too_soon"
    static let codeBadRequest = "bad_request"
    static let codeBadPin = "bad_pin"
    static let codeBadPassword = "bad_password"
    static let codeBackoff = "backoff"
}

/// The vault calls of ``ProfileManager``.
struct VaultProfileOps: ProfileOps {
    let api: VaultApi

    func accountNameSet(pin: String, password: String, firstName: String, lastName: String) async throws -> NameRequest {
        try await api.accountNameSet(pin: pin, password: password, firstName: firstName, lastName: lastName)
    }
}

public extension NameRequestView {
    /// The vault's request; nil for one this app cannot read (an unknown state). [reason] only with `refused`.
    static func of(_ r: NameRequest) -> NameRequestView? {
        guard let st = NameRequestState.of(r.state) else { return nil }
        return NameRequestView(
            seq: r.seq, firstName: r.firstName, lastName: r.lastName, requestedAt: OwnerCheckManager.instant(r.requestedAt),
            state: st, reason: st == .refused ? r.reason : nil
        )
    }

    /// The request as the account record keeps it.
    var wire: NameRequest {
        NameRequest(
            seq: seq, firstName: firstName, lastName: lastName, requestedAt: requestedAt.map(OwnerCheckManager.format),
            state: state.wire, reason: reason
        )
    }
}

extension NameRequestState {
    /// The wire state.
    var wire: String {
        switch self {
        case .pending: "pending"
        case .applied: "applied"
        case .refused: "refused"
        }
    }
}
