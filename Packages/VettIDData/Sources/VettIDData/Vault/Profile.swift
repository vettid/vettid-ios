import Foundation
import Observation
import VettIDCrypto
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

/// The member's own shared profile (VAULT-MESSAGING §10.8): the read-only core ([firstName], [lastName] from the account
/// snapshot, the vault's identity key as [fingerprint]) and the editable display name ([displayName], "" for none) and
/// [photo] (the standard base64 of a JPEG or PNG of at most 65,536 bytes; nil for none). In memory only, never printed
/// with its photo. Mirrors vettid-android `OwnProfile`.
public struct OwnProfile: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public var version: UInt64
    public var displayName: String
    public var firstName: String?
    public var lastName: String?
    public var fingerprint: String?
    public var photo: String?

    public init(
        version: UInt64, displayName: String, firstName: String?, lastName: String?, fingerprint: String?, photo: String? = nil
    ) {
        self.version = version
        self.displayName = displayName
        self.firstName = firstName
        self.lastName = lastName
        self.fingerprint = fingerprint
        self.photo = photo
    }

    public var fullName: String? { AccountNames.full(firstName, lastName) }

    public var description: String { "OwnProfile(version: \(version), photo: \(photo == nil ? "none" : "set"))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The member's shared profile and the account's names (VAULT-MESSAGING §10.8). Failures other than a
/// ``NameChangeOutcome`` are ``VaultFailure``s. Mirrors vettid-android `ProfileRepository`.
@MainActor
public protocol ProfileRepository: AnyObject, Observable, Sendable {
    /// Nil until read (``refreshProfile()``), and again once the vault is no longer open on this phone.
    var profile: OwnProfile? { get }

    /// Re-reads `profile.get`.
    func refreshProfile() async throws

    /// `profile.set{name}`: the display name, trimmed ("" removes it). Never the core, which is read-only.
    func setDisplayName(_ name: String) async throws

    /// `profile.set{photo}`: [photo] the base64 JPEG or PNG (at most 65,536 bytes of image); "" removes it.
    func setPhoto(_ photo: String) async throws

    /// `account.name.set` with the PIN, the credential password and the two names, which the caller has checked with
    /// ``AccountNames/check(_:)`` (they are sent normalised). The account's names change only once VettID applied the
    /// request; the outcome arrives in the account (``AccountInfo/nameRequest``).
    func changeName(pin: String, password: String, firstName: String, lastName: String) async -> NameChangeOutcome
}

/// The vault calls behind ``ProfileManager``. Mirrors vettid-android `ProfileOps`.
public protocol ProfileOps: Sendable {
    func profileGet() async throws -> Profile
    func profileSet(version: UInt64, name: String) async throws -> UInt64
    func profileSetPhoto(version: UInt64, photo: String) async throws -> UInt64
    func accountNameSet(pin: String, password: String, firstName: String, lastName: String) async throws -> NameRequest
}

/// ``ProfileRepository`` over ``ProfileOps``. [onRequest] keeps a new name request with the account, with the [mark]
/// read before the request was sent (the account record it belongs to); [checksLeft] re-reads the owner check's count
/// after a failed PIN or password (§3.6.4: a name change counts as a check). [profileOps] are the calls of the shared
/// profile ([ops] when nil); [quietOps] those of a read nobody asked for (the vault opening, `profile.changed`), which
/// never open a session ([profileOps] when nil).
///
/// The profile read is the member's own (the names and the photo): **memory only**, forgotten by ``clear()`` whenever
/// the vault is not open (IOS-PLAN §4.7). An answer is kept only while [open] says the vault is open and no ``clear()``
/// came since its request was sent, so a read on its way when the vault locks never brings the profile back. Mirrors
/// vettid-android `ProfileManager`.
@MainActor
@Observable
public final class ProfileManager: ProfileRepository {
    public private(set) var profile: OwnProfile?

    @ObservationIgnored private let ops: @MainActor () async throws -> any ProfileOps
    @ObservationIgnored private let profileOps: @MainActor () async throws -> any ProfileOps
    @ObservationIgnored private let quietOps: @MainActor () async throws -> any ProfileOps
    @ObservationIgnored private let onRequest: @MainActor (NameRequestView, _ mark: Int) -> Void
    @ObservationIgnored private let checksLeft: @MainActor () async -> Int?
    @ObservationIgnored private let mark: @MainActor () -> Int
    @ObservationIgnored private let open: @MainActor () -> Bool
    @ObservationIgnored private let notes: FailureNotes
    /// Bumped by every ``clear()``: an answer to a request sent before it is dropped.
    @ObservationIgnored private var generation = 0

    public init(
        ops: @escaping @MainActor () async throws -> any ProfileOps,
        profileOps: (@MainActor () async throws -> any ProfileOps)? = nil,
        quietOps: (@MainActor () async throws -> any ProfileOps)? = nil,
        onRequest: @escaping @MainActor (NameRequestView, _ mark: Int) -> Void,
        checksLeft: @escaping @MainActor () async -> Int?,
        mark: @escaping @MainActor () -> Int = { 0 },
        open: @escaping @MainActor () -> Bool = { true },
        notes: FailureNotes = .none
    ) {
        self.ops = ops
        self.profileOps = profileOps ?? ops
        self.quietOps = quietOps ?? profileOps ?? ops
        self.onRequest = onRequest
        self.checksLeft = checksLeft
        self.mark = mark
        self.open = open
        self.notes = notes
    }

    /// Forgets the profile read (the vault is not open: a lock, the hold or the due state, a sign-out, a wipe; IOS-PLAN
    /// §4.7).
    public func clear() {
        generation += 1
        profile = nil
    }

    /// [f] of the profile now, kept while the vault is open and no ``clear()`` came since [g] was read.
    private func keep(_ g: Int, _ f: (OwnProfile?) -> OwnProfile?) {
        if g == generation, open() { profile = f(profile) }
    }

    public func refreshProfile() async throws { try await refreshProfile(quietly: false) }

    /// `profile.get`; [quietly]: a read nobody asked for, only over the session open now. The core is kept only when it
    /// keeps the receiver's rules (§10.8), the fingerprint shown from `ik`.
    public func refreshProfile(quietly: Bool) async throws {
        let g = generation
        let calls = quietly ? quietOps : profileOps
        let p = try await notes.run { try await calls().profileGet() }
        keep(g) { _ in Self.own(p) }
    }

    /// The vault opened, or its profile changed (`sync.event{profile.changed}`): read again; a failure keeps what was read.
    public func refreshQuietly() {
        Task { [weak self] in try? await self?.refreshProfile(quietly: true) }
    }

    public func setDisplayName(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = generation
        let version = try await notes.run {
            let o = try await profileOps()
            let current = try await currentVersion(o)
            return try await o.profileSet(version: current, name: trimmed)
        }
        keep(g) { current in
            guard var p = current else { return nil }
            p.version = version
            p.displayName = trimmed
            return p
        }
        try? await refreshProfile()
    }

    public func setPhoto(_ photo: String) async throws {
        let g = generation
        let version = try await notes.run {
            let o = try await profileOps()
            let current = try await currentVersion(o)
            return try await o.profileSetPhoto(version: current, photo: photo)
        }
        keep(g) { current in
            guard var p = current else { return nil }
            p.version = version
            p.photo = photo.isEmpty ? nil : photo
            return p
        }
        try? await refreshProfile()
    }

    /// The version a change is sent against: the one read, else the vault's now.
    private func currentVersion(_ o: any ProfileOps) async throws -> UInt64 {
        if let v = profile?.version { return v }
        return try await o.profileGet().version
    }

    static func own(_ p: Profile) -> OwnProfile {
        OwnProfile(
            version: p.version,
            displayName: p.name,
            firstName: AccountNames.isValidCore(p.firstName) ? p.firstName : nil,
            lastName: AccountNames.isValidCore(p.lastName) ? p.lastName : nil,
            fingerprint: p.ik.flatMap(IkFingerprint.formatB64),
            photo: p.photo.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    public func changeName(pin: String, password: String, firstName: String, lastName: String) async -> NameChangeOutcome {
        guard let first = AccountNames.normalize(firstName), let last = AccountNames.normalize(lastName) else { return .invalid }
        let since = mark()
        let noteMark = notes.mark()
        do {
            let r = try await ops().accountNameSet(pin: pin, password: password, firstName: first, lastName: last)
            let view = NameRequestView.of(r)
                ?? NameRequestView(seq: r.seq, firstName: first, lastName: last, requestedAt: nil, state: .pending)
            onRequest(view, since)
            return .requested(view)
        } catch {
            let f = notes.note(VaultFailures.map(error), noteMark, nil) as? VaultFailure ?? VaultFailure(.other)
            return await failed(f)
        }
    }

    private func failed(_ e: VaultFailure) async -> NameChangeOutcome {
        // A refusal of `credential.utk.get` before the request (its resync's `too_soon` is the resync's 10 minutes, not the
        // name's; VAULT-MESSAGING 0.52.0 §3.5.4) is the vault's code, never the name change's own texts, as vettid-android
        // `fromUtkGet` does.
        if (e.cause as? VaultOpError)?.type == "credential.utk.get" { return .failed(e.kind, code: e.code) }
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

/// The vault calls of ``ProfileManager``. Mirrors vettid-android `VaultProfileOps`.
struct VaultProfileOps: ProfileOps {
    let api: VaultApi
    /// Runs before a name change is sent: refuses it while a change of PIN or password is unresolved (VAULT-MESSAGING
    /// §11.14.9 "A lost answer").
    var gate: @Sendable () async throws -> Void = {}

    func profileGet() async throws -> Profile { try await api.profileGet() }

    func profileSet(version: UInt64, name: String) async throws -> UInt64 { try await api.profileSet(version: version, name: name) }

    func profileSetPhoto(version: UInt64, photo: String) async throws -> UInt64 {
        try await api.profileSet(version: version, photo: photo)
    }

    func accountNameSet(pin: String, password: String, firstName: String, lastName: String) async throws -> NameRequest {
        try await gate()
        return try await api.accountNameSet(pin: pin, password: password, firstName: firstName, lastName: lastName)
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
