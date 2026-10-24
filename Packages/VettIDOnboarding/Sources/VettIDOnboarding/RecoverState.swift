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
    /// (IOS-PLAN 0.1.38 §4.9, "A phone that could not tell") An open this phone sent got no readable answer and its recovery has
    /// ended; two status reads said so. The text "We could not tell whether your last attempt recovered the vault. You can start a
    /// new recovery on the account site and use this phone for it; nothing on this phone is deleted.", and the code step as
    /// ``intro`` has it (``RecoverViewModel/scan()``, ``RecoverViewModel/type()``): the new code is claimed with the same key.
    case couldNotTell
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
    /// (IOS-PLAN 0.1.38 §4.9) A recovery code of another vault than the one this phone is recovering: nothing was registered,
    /// and nothing on this phone is deleted.
    case otherVault
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

/// What a refusal of the data layer asks of the member, for the screens to text (I3.4b has the words; chosen; not in the
/// spec). Not a ``FailureKind``: the kinds have texts of their own in the data layer.
public enum RecoverGuidance: Equatable, Sendable {
    /// `recovery_open_sent`: an open went out and the vault may have adopted this phone: the lost-ok finish ("finish with your
    /// PIN", ``RecoveryOpenViewModel/finishLostOk()``), not a new registration or a start over.
    case finishWithPin
    /// `recovery_opened`: this recovery already succeeded on this phone; finish it, never start over.
    case alreadyRecovered
    /// `recovery_open_pending`: the member API says the recovery is still registered and this phone is not its app: the open can
    /// be tried again (a start over or a new registration waits for an answer to it). It can also mean the vault has just adopted
    /// it (only the next key is set yet), so the lost-ok finish with the PIN is offered beside another open.
    case tryOpenAgain
    /// `recovery_open_unknown`: the member API could not say whether the vault adopted this phone: try again in a moment.
    case retry
    /// `recovery_registered`: this phone is registered for another recovery, which a start over ends first.
    case startOverFirst
}

/// The state of the recovery flow. The typed entry is held in memory only: never in saved state, on disk, in a log or on the
/// clipboard, and left out of the description. Mirrors vettid-android `RecoverUiState`.
public struct RecoverState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Wrong codes from this phone for one recovery, after which the vault voids it (§11.11.3).
    public static let maxWrongCodes = 5
    /// The account site's "Delete my vault and start over" page (MEMBER-API 2.1.0).
    public static let startOverPath = "/account/vault/deletion/"

    /// The characters of one group of the typed code, and the groups of all of it (``RecoveryCodes``), for the screens.
    public static let codeGroup = RecoveryCodes.group
    public static let codeGroups = RecoveryCodes.typedGroups

    /// Whether the typed field keeps [character] (a digit or letter of the code, also after I, L and O are read as 1 and 0); a
    /// separator or a refused character is not kept.
    public static func keepsTyped(_ character: Character) -> Bool { !RecoveryCodes.typedInput(String(character)).text.isEmpty }

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
    /// (IOS-PLAN 0.1.38 §4.9) Where the rule for a phone that could not tell stands: ``CouldNotTellStage/newCode`` is the step
    /// ``RecoverStep/couldNotTell``; ``CouldNotTellStage/finishWithPin`` (the claim of a new code answered `409 key_in_use`, or
    /// two reads of `200`) is the PIN of ``RecoveryOpenViewModel/finishLostOk()`` on the ``RecoverStep/open`` step;
    /// ``CouldNotTellStage/contact`` adds the second text, "Your vault took this phone, but it cannot be unlocked right now.
    /// Contact VettID."; ``CouldNotTellStage/unlockOrNewCode`` (the new identity's recovery ended too) is that PIN with the code
    /// steps beside it (``newCodeAllowed``).
    public var couldNotTell = CouldNotTellStage.none

    /// (§4.9) A new recovery code may be scanned or typed from here: it registers the new identity again, never a third.
    public var newCodeAllowed: Bool { couldNotTell == .newCode || couldNotTell == .unlockOrNewCode }

    public init(step: RecoverStep = .loading, startOverURL: String = "", accountHost: String = "") {
        self.step = step
        self.startOverURL = startOverURL
        self.accountHost = accountHost
    }

    /// What ``errorCode`` asks of the member, when it is one of the data layer's refusals of a registration or a start over.
    public var guidance: RecoverGuidance? {
        switch errorCode {
        case VaultManager.codeRecoveryOpenSent: .finishWithPin
        case MoveCodes.recoveryOpened: .alreadyRecovered
        case VaultManager.codeRecoveryOpenPending: .tryOpenAgain
        case VaultManager.codeRecoveryOpenUnknown: .retry
        case VaultManager.codeRecoveryRegistered: .startOverFirst
        default: nil
        }
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
    /// (IOS-PLAN 0.1.38 §4.9) Reads the rule's status again when it is due (a return to the foreground, "Check again", after the
    /// open's answer): ``RecoverState/couldNotTell`` and, for a new code, the step ``RecoverStep/couldNotTell`` follow.
    func checkEnded()
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
    /// From a code step whose refusal is ``RecoverGuidance``: to the open step.
    func showOpen()
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
    public func checkEnded() {}
    public func retryStage() {}
    public func back() -> Bool { false }
    public func scanned(_ text: String) {}
    public func type() {}
    public func setTyped(_ v: String) {}
    public func submitTyped() {}
    public func showOpen() {}
    public func askStartOver() {}
    public func dismissStartOver() {}
    public func confirmStartOver() {}
    public func finish() {}
}
