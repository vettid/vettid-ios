import Foundation
import VettIDData

/// Where the recovery open stands (ANDROID-PLAN 0.1.40 "Recovery on the new phone"). Mirrors vettid-android `OpenStep`.
public enum OpenStep: Equatable, Sendable, CaseIterable {
    /// Both fields on one screen.
    case enter
    /// "This is what will be sent": a step that cannot be skipped.
    case check
    case sending
    /// The vault answered (anything but `ok`).
    case answered
    /// The vault answered `ok` earlier but the phone could not finish opening it (the handshake or the credential did not
    /// complete, or the app stopped): the PIN alone finishes it, and no new open is sent.
    case finish
    /// Recovered: the `ok` text, then the app opens.
    case done
}

public enum OpenWarning: Equatable, Sendable {
    case second
    case fewLeft
}

/// The recovery open's state. The PIN and the password are held in memory only and never written anywhere; they are left
/// out of the description. Mirrors vettid-android `RecoveryOpenUiState`.
public struct RecoveryOpenState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let minPin = 6
    public static let maxPin = 32
    /// How many attempts are left from which a warning stands above the check.
    static let low = 3
    static let codeDeviceSecret = "device_secret"
    /// An open whose answer this phone could not read (``VaultFailure`` code).
    public static let codeUnreadable = "unreadable_result"

    public var step: OpenStep = .enter
    public var pin = ""
    public var password = ""
    public var showPin = false
    public var showPassword = false
    /// The last answer, with the attempts the counter reported.
    public var outcome: RecoveryOpenOutcome?
    /// A failure before the vault answered (network, the service).
    public var failure: FailureKind?
    /// ``failure``'s code (`unreadable_result`, …).
    public var failureCode: String?
    /// The member asked to erase VettID from this phone (``canErase``); the confirmation is shown.
    public var confirmErase = false
    /// (0.34.0 §11.14.6 "A lost ok") ``OpenStep/finish`` after an open whose answer never arrived or could not be read: the
    /// PIN unlocks with this phone's secret, and a result with the vault's bundle finishes the recovery.
    public var lostOk = false
    /// Attempts used, as last known (nil before the counter ever answered for this recovery, also after a restart).
    public var used: Int?
    /// An open after one that got no answer was answered `wait` or `attempt_lost` (§11.14.6 "A right entry that could not be
    /// completed").
    public var rightButIncomplete = false
    /// The member continued after `ok` and the vault opened on this phone (``RecoveryOpenViewModel/openApp()``): the
    /// recovery's own screen hands over to the end of setup.
    public var opened = false
    /// (IOS-PLAN 0.1.35 §4.9, "A phone that could not tell") ``CouldNotTellStage/finishWithPin`` puts this screen at the PIN of
    /// ``OpenStep/finish`` (the unlock with this phone's secret, the new identity first if it registered, then the earlier one);
    /// ``CouldNotTellStage/contact`` adds the second text, "Your vault took this phone, but it cannot be unlocked right now.
    /// Contact VettID."; ``CouldNotTellStage/unlockOrNewCode`` (the new identity's recovery ended too) is the same PIN with "Use a
    /// new recovery code" beside it (``newCodeAllowed``, ``RecoverViewModel/scan()``, ``RecoverViewModel/type()``).
    /// ``CouldNotTellStage/newCode`` after an answer is the step ``RecoverStep/couldNotTell`` (``RecoverViewModel/checkEnded()``).
    public var couldNotTell = CouldNotTellStage.none

    public init(step: OpenStep = .enter, used: Int? = nil) {
        self.step = step
        self.used = used
    }

    public var pinValid: Bool { (Self.minPin...Self.maxPin).contains(pin.count) && pin.allSatisfy { $0.isASCII && $0.isNumber } }

    /// The second text of the rule is shown (a day of refusals to the unlock after `409 key_in_use`).
    public var contactVettID: Bool { couldNotTell == .contact }

    /// (IOS-PLAN 0.1.35 §4.9) The answer ruled recovery out (`exhausted`, `closed` or `not_armed` to the new identity's fresh
    /// open): the text "This phone could not recover your vault. Nothing on this phone is deleted. Contact VettID at
    /// support@vettid.org." (`recover_could_not_recover`) with the action "Email support", which opens ``SupportMail/url``. Not
    /// terminal: a later recovery the member starts still uses this phone (``newCodeAllowed`` once the reads allow it).
    public var couldNotRecover: Bool { outcome?.contactCouldNotRecover == true }

    /// (§4.9) A new recovery code may be used with this phone now: it registers the new identity again (never a third).
    public var newCodeAllowed: Bool { couldNotTell == .unlockOrNewCode || couldNotTell == .newCode }

    public var canContinue: Bool { pinValid && !password.isEmpty }

    /// While finishing an `ok` recovery, the enclave itself answered that this phone's key no longer opens the vault
    /// (`device_secret` at both epochs, a sealed answer nobody else can make): the way out is to erase VettID from this
    /// phone. Answers the host or the member API can produce (random bytes, a 401) never offer it.
    public var canErase: Bool {
        step == .finish && !lostOk && outcome?.opened == true && outcome?.code == Self.codeDeviceSecret
    }

    /// Before the second attempt, and from three or fewer left: a warning above the check.
    public var warning: OpenWarning? {
        if used == 1 { return .second }
        if let used, RecoveryOpenOutcome.attempts - used <= Self.low { return .fewLeft }
        return nil
    }

    public var description: String {
        let (outcome, failure, used) = (outcome?.code ?? "nil", failure.map { "\($0)" } ?? "nil", used.map(String.init) ?? "nil")
        return "RecoveryOpenState(step: \(step), outcome: \(outcome), failure: \(failure), used: \(used))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The text of an answer in the plan's table (ANDROID-PLAN 0.1.41), as a key; the screens say it (their strings table).
/// Mirrors vettid-android's `R.string.onboarding_open_*` of `openAnswerText`.
public enum OpenAnswerKey: String, Equatable, Sendable, CaseIterable {
    case rightIncomplete = "onboarding_open_right_incomplete"
    case wrongWait = "onboarding_open_wrong_wait"
    case wrong = "onboarding_open_wrong"
    case wrongAgain = "onboarding_open_wrong_again"
    case attemptLost = "onboarding_open_attempt_lost"
    case quiet = "onboarding_open_quiet"
    case quietNoDate = "onboarding_open_quiet_nodate"
    case quietNothing = "onboarding_open_quiet_nothing"
    case quietUsed = "onboarding_open_quiet_used"
    case wait = "onboarding_open_wait"
    case waitNoDate = "onboarding_open_wait_nodate"
    case waitNothing = "onboarding_open_wait_nothing"
    case busy = "onboarding_open_busy"
    case retry = "onboarding_open_retry"
    case retryUsed = "onboarding_open_retry_used"
    case storedMismatch = "onboarding_open_stored_mismatch"
    case storedMismatchRight = "onboarding_open_stored_mismatch_right"
    case exhausted = "onboarding_open_exhausted"
    case closed = "onboarding_open_closed"
    case notArmed = "onboarding_open_not_armed"
    case counterUnavailable = "onboarding_open_counter_unavailable"
    case ok = "onboarding_open_ok"
    case okPlain = "onboarding_open_ok_plain"
    case noRecovery = "onboarding_open_no_recovery"
    case noRecoveryUnanswered = "onboarding_open_no_recovery_unanswered"
    case expired = "onboarding_open_expired"
    case attestation = "onboarding_open_attestation"
    case manifest = "onboarding_open_manifest"
    case wrongRelease = "onboarding_open_wrong_release"
    case badRequest = "onboarding_open_bad_request"
    case other = "onboarding_open_other"
    // This phone's own unlock while it finishes an `ok` recovery.
    case finishBadPin = "onboarding_open_finish_bad_pin"
    case finishBackoff = "onboarding_open_finish_backoff"
    case lostNotHere = "onboarding_open_lost_not_here"
    case finishFailed = "onboarding_open_finish_failed"
}

/// The text of an answer: its key and arguments, then, when set, `retry_at` ([withRetryAt]). The date the app was last used
/// is not shown: nothing the app reads carries the vault's quiet period. [number]: the attempts left (or, for `ok`, used)
/// where the text names them; [code]: the vault's code for ``OpenAnswerKey/other``. [attemptsLeft]: a line under it with the
/// attempts left, for the answers whose text does not say whether this request used one. Mirrors vettid-android
/// `OpenAnswerText`.
public struct OpenAnswerText: Equatable, Sendable {
    public var key: OpenAnswerKey
    public var number: Int?
    public var code: String?
    public var withRetryAt: Bool
    public var attemptsLeft: Int?

    public init(_ key: OpenAnswerKey, number: Int? = nil, code: String? = nil, withRetryAt: Bool = false, attemptsLeft: Int? = nil) {
        self.key = key
        self.number = number
        self.code = code
        self.withRetryAt = withRetryAt
        self.attemptsLeft = attemptsLeft
    }
}

/// Every answer of the plan's table; `left` is 10 less the attempts used, when known. [rightButIncomplete]: the open before
/// this one got no answer. `quiet` and `wait` say nothing about whether this request used an attempt (the result does not
/// tell), only how many are left.
public func openAnswerText(_ o: RecoveryOpenOutcome, rightButIncomplete: Bool) -> OpenAnswerText {
    let left = o.left ?? RecoveryOpenOutcome.attempts
    if rightButIncomplete && o.retryAt != nil { return OpenAnswerText(.rightIncomplete, number: left, withRetryAt: true) }
    if o.opened { return OpenAnswerText(openedKey(o.code)) }
    return OpenAnswerTable.text(o, left: left)
}

private func openedKey(_ code: String) -> OpenAnswerKey {
    switch code {
    case "bad_pin": .finishBadPin
    case "backoff": .finishBackoff
    case VaultManager.codeNoBundle: .lostNotHere
    default: .finishFailed
    }
}

private enum OpenAnswerTable {
    // One line per answer of the table.
    static func text(_ o: RecoveryOpenOutcome, left: Int) -> OpenAnswerText { // swiftlint:disable:this cyclomatic_complexity
        switch o.code {
        case "wrong": wrong(o, left)
        case "wrong_again": OpenAnswerText(.wrongAgain)
        case "attempt_lost": OpenAnswerText(.attemptLost, number: left)
        case "quiet": quiet(o, left)
        case "wait": wait(o, left)
        case "busy": OpenAnswerText(.busy)
        // (0.34.0) A retry after the spend used an attempt (the entry may have been right).
        case "retry": retry(o, left)
        // Before the spend nothing was used; after it, the right attempt was (attempt_used; an older vault: attempts).
        case "stored_mismatch", "vault_missing": storedMismatch(o)
        case "exhausted": OpenAnswerText(.exhausted)
        case "closed": OpenAnswerText(.closed)
        case "not_armed": OpenAnswerText(.notArmed)
        case "counter_unavailable": OpenAnswerText(.counterUnavailable)
        case "ok": ok(o)
        // Refusals before anything is counted (§11.14.6 step 1). After an open that got no answer the recovery may have
        // completed on the way; this phone cannot finish it.
        case "no_recovery": OpenAnswerText(o.afterUnanswered ? .noRecoveryUnanswered : .noRecovery)
        case "expired": OpenAnswerText(.expired)
        case "attestation": OpenAnswerText(.attestation)
        case "manifest": OpenAnswerText(.manifest)
        case "wrong_release": OpenAnswerText(.wrongRelease)
        case "bad_request": OpenAnswerText(.badRequest)
        default: OpenAnswerText(.other, code: o.code)
        }
    }

    static func wrong(_ o: RecoveryOpenOutcome, _ left: Int) -> OpenAnswerText {
        o.retryAt != nil ? OpenAnswerText(.wrongWait, number: left, withRetryAt: true) : OpenAnswerText(.wrong, number: left)
    }

    static func retry(_ o: RecoveryOpenOutcome, _ left: Int) -> OpenAnswerText {
        o.attemptUsed == true ? OpenAnswerText(.retryUsed, number: left) : OpenAnswerText(.retry)
    }

    static func storedMismatch(_ o: RecoveryOpenOutcome) -> OpenAnswerText {
        (o.attemptUsed ?? (o.used != nil)) ? OpenAnswerText(.storedMismatchRight) : OpenAnswerText(.storedMismatch)
    }

    static func ok(_ o: RecoveryOpenOutcome) -> OpenAnswerText {
        o.used.map { OpenAnswerText(.ok, number: $0) } ?? OpenAnswerText(.okPlain)
    }

    /// `quiet` (§11.14.6, ANDROID-PLAN 0.1.41): whether this request used an attempt comes only from `attempt_used`; a vault
    /// that does not say gets the neutral text with the attempts left.
    static func quiet(_ o: RecoveryOpenOutcome, _ left: Int) -> OpenAnswerText {
        if o.attemptUsed == true { return OpenAnswerText(.quietUsed, number: left) }
        if o.retryAt == nil { return OpenAnswerText(.quietNoDate, attemptsLeft: o.attemptUsed == nil ? o.left : nil) }
        if o.attemptUsed == false { return OpenAnswerText(.quietNothing, withRetryAt: true) }
        return OpenAnswerText(.quiet, withRetryAt: true, attemptsLeft: o.left)
    }

    /// `wait`: with an attempt used, as `attempt_lost`; with none, "Nothing was used"; unknown, neutral.
    static func wait(_ o: RecoveryOpenOutcome, _ left: Int) -> OpenAnswerText {
        if o.attemptUsed == true { return OpenAnswerText(.attemptLost, number: left) }
        if o.retryAt == nil { return OpenAnswerText(.waitNoDate, attemptsLeft: o.attemptUsed == nil ? o.left : nil) }
        if o.attemptUsed == false { return OpenAnswerText(.waitNothing, withRetryAt: true) }
        return OpenAnswerText(.wait, withRetryAt: true, attemptsLeft: o.left)
    }
}

/// Answers after which this recovery cannot go on: a try again cannot help.
private let endedAnswers: Set<String> = [
    "exhausted", "closed", "not_armed", "stored_mismatch", "no_recovery", "expired", "attestation", "bad_request",
]

/// Answers that end this recovery but leave a new one possible: "Start a new recovery".
private let newRecoveryAnswers: Set<String> = ["no_recovery", "expired"]

/// Whether an answer leaves room for another try now or later (the fields come back).
public func openCanTryAgain(_ code: String?) -> Bool { !(code.map(endedAnswers.contains) ?? false) }

/// Whether an answer leads to starting a new recovery (this phone forgets this one; a new code on the account site).
public func openNeedsNewRecovery(_ code: String?) -> Bool { code.map(newRecoveryAnswers.contains) ?? false }

/// "2 d 03:04:05" until [at].
public func openCountdown(until at: Date, now: Date) -> String {
    let s = Int(max(at.timeIntervalSince(now).rounded(.down), 0))
    let (d, rest) = (s / 86_400, s % 86_400)
    let hms = String(format: "%02d:%02d:%02d", rest / 3_600, rest % 3_600 / 60, rest % 60)
    return d > 0 ? "\(d) d \(hms)" : hms
}

/// The recovery's wait unit on a vault with a time scale (STAGING-TIME-SCALE §2.1 and T6: `recovery_wait_unit_seconds` is 600
/// on staging, and the time scale does not divide it again; 86,400 in production). The vault does not tell the app its unit; a
/// vault with a time scale other than 1 is a staging vault, so this is its unit.
public let recoveryWaitUnitScaledSeconds: TimeInterval = 600
