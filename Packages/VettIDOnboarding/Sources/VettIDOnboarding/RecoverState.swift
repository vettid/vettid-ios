import Foundation
import VettIDAltChan
import VettIDData

/// The steps of a recovery on this phone (VAULT-MESSAGING §11.11, §11.14.6; ANDROID-PLAN §4 "Onboarding"). Mirrors
/// vettid-android `RecoverStep`. IOS-PLAN ID8: the app implements release R's recovery only, which has one screen for the
/// PIN and the password (``open``, ANDROID-PLAN 0.1.40); the earlier recovery's own steps for the PIN, the password and
/// "this recovery has ended" (`PIN`, `PASSWORD`, `ENDED`) are not on iOS (chosen; not in the spec).
public enum RecoverStep: Equatable, Sendable, CaseIterable {
    case loading
    /// Where the recovery stands could not be read (``RecoverState/error`` says why): nothing is offered but a retry, so that a
    /// registered recovery is never taken for none.
    case stageFailed
    /// What is needed, and where the code comes from (the account portal; the app never signs in).
    case intro
    case scan
    /// The code typed instead of scanned (VAULT-MESSAGING 0.25.0 §11.11.10; ANDROID-PLAN 0.1.33).
    case type
    /// `vault.recovery.register` (§11.11.3).
    case registering
    /// The PIN and the password together (§11.14.6): ``RecoveryOpenViewModel``'s screen. Android's `PIN` step with a phone
    /// secret.
    case open
    /// The vault keeps no backup copy of its credential (`no_backup`, `409 recovery_unavailable`; VAULT-MESSAGING 0.16.0):
    /// it cannot be recovered, only deleted on the account site and replaced by a new one.
    case noBackup
}

/// Why the code was refused, for the member (§11.11.3 codes, the API's 409). Mirrors vettid-android `CodeRefusal`.
public enum CodeRefusal: Equatable, Sendable, CaseIterable {
    case badCode
    case voided
    case expired
    case tooEarly
    case gone
    case attestation
    case retry
    case notACode
    /// A recovery QR of another environment's portal (its `api`, §11.11.2, 0.15.0).
    case otherEnvironment
    /// A recovery QR without `api` (an account site from before 0.15.0): apps of 0.15.0 require it.
    case noApi
    /// The member API's `409 recovery_not_available` at the claim or the register.
    case notAvailable
    /// (VAULT-MESSAGING 0.34.0 §11.10.9) The vault's release implements release R without `recovery_offered`: nothing is
    /// sent ("This vault's release does not offer recovery").
    case notOffered
}

/// Why the typed entry is not (yet) a code this app sends (§11.11.10 steps 1 and 2). None of these is a wrong code: nothing
/// reaches the member API or the vault, and nothing is counted. Mirrors vettid-android `TypedProblem`.
public enum TypedProblem: Equatable, Sendable, CaseIterable {
    /// A `U` was typed: the alphabet has none, and it is never guessed to be a `V`.
    case letterU
    /// A character that is neither a digit nor a letter.
    case otherCharacter
    /// 48 characters whose check characters do not match this app's account site: a typing mistake, or another site's code.
    case badCheck
    /// Exactly the 32 characters an account page showed before MEMBER-API 2.4.0.
    case shortCode
    /// Fewer than 12 groups.
    case incomplete
}

/// The state of the recovery flow. The typed entry is held in memory only: never in saved state, on disk, in a log or on the
/// clipboard, and left out of the description. Mirrors vettid-android `RecoverUiState`.
public struct RecoverState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Wrong codes from this phone for one recovery, after which the vault voids it (§11.11.3).
    public static let maxWrongCodes = 5
    /// The account site's "Delete my vault and start over" page (MEMBER-API 2.1.0).
    public static let startOverPath = "/account/vault/deletion/"

    public var step: RecoverStep = .loading
    /// The account the vault belongs to, masked (`email_hint` from the claim, §11.11.7).
    public var emailHint = ""
    public var refusal: CodeRefusal?
    /// The other environment's `api` of a refused QR.
    public var otherApi: String?
    /// The typed entry in canonical form (at most 48 characters).
    public var typed = ""
    public var typedProblem: TypedProblem?
    /// The group (1 to 12) a refused character would have gone into, for ``TypedProblem/letterU`` and
    /// ``TypedProblem/otherCharacter``.
    public var typedGroup = 0
    /// The host of this app's account site, for ``TypedProblem/badCheck``'s text.
    public var accountHost = ""
    /// Seconds until the member API takes another claim from this network (`429`'s `Retry-After`); 0 when unknown or over.
    public var retrySeconds: Int64 = 0
    /// Wrong codes sent from this phone for the current recovery (the vault voids it at 5).
    public var wrongCodes = 0
    /// The account site's "Delete my vault and start over" page, for ``RecoverStep/noBackup``.
    public var startOverURL = ""
    /// "Start over" was asked for on the open step: the confirmation shows.
    public var confirmStartOver = false
    public var busy = false
    public var error: FailureKind?
    public var errorCode: String?

    public init(step: RecoverStep = .loading, startOverURL: String = "", accountHost: String = "") {
        self.step = step
        self.startOverURL = startOverURL
        self.accountHost = accountHost
    }

    /// Complete groups of four typed so far (of ``RecoveryCodes/typedGroups``).
    public var typedGroups: Int { typed.count / RecoveryCodes.group }

    /// All 48 characters are there: **Continue** checks them.
    public var typedComplete: Bool { typed.count == RecoveryCodes.typedLength }

    public var description: String {
        "RecoverState(step: \(step), busy: \(busy), refusal: \(refusal.map { "\($0)" } ?? "nil"), error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What the recovery screens can ask for: ``RecoverViewModel``, or ``NoRecoverActions`` in previews and the screen
/// catalog. Mirrors vettid-android `RecoverActions` (the earlier recovery's PIN and password actions are not here).
@MainActor
public protocol RecoverActions: AnyObject, Sendable {
    func scan()
    /// Reads where the recovery stands again, after ``RecoverStep/stageFailed``.
    func retryStage()
    /// Back within the flow; false when the member leaves it (the onboarding flow takes over).
    @discardableResult func back() -> Bool
    func scanned(_ text: String)
    /// "Type the code instead".
    func type()
    /// The typed field changed (typing or a paste).
    func setTyped(_ v: String)
    /// **Continue** on the typed entry.
    func submitTyped()
    /// "Start over" on the open step: asks first (``RecoverState/confirmStartOver``).
    func askStartOver()
    func dismissStartOver()
    /// Confirmed: this phone forgets the recovery it registered (the recovery itself is not cancelled by that).
    func confirmStartOver()
    func finish()
}

/// Actions that do nothing: the screens rendered with sample states (previews, the screen catalog).
@MainActor
public final class NoRecoverActions: RecoverActions {
    public init() {}

    public func scan() {}
    public func retryStage() {}
    public func back() -> Bool { false }
    public func scanned(_ text: String) {}
    public func type() {}
    public func setTyped(_ v: String) {}
    public func submitTyped() {}
    public func askStartOver() {}
    public func dismissStartOver() {}
    public func confirmStartOver() {}
    public func finish() {}
}
