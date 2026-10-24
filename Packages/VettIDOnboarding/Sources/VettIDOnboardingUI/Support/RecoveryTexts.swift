import Foundation
import VettIDData
import VettIDOnboarding

/// The recovery's outcomes as the screens say them: a state's refusal, a typed entry's problem, an answer of the open and
/// its warning, each resolved to the words of ``RecoveryStrings`` and ``RecoveryOpenStrings``. Mirrors vettid-android
/// `CodeRefusalNotice`, `typedProblemText`, `openAnswerArgs` and `openWarningText`.
enum RecoveryTexts {
    /// The text of [r] for [s]. [timeScale]: the vault's, for the recovery's delay ("24 hours"; on staging "1 hour").
    static func refusal(_ r: CodeRefusal, _ s: RecoverState, timeScale: UInt64) -> String { // swiftlint:disable:this cyclomatic_complexity
        switch r {
        case .badCode: RecoveryStrings.recoverBadCode(s.wrongCodes)
        case .voided: RecoveryStrings.recoverVoided
        case .expired: RecoveryStrings.recoverCodeExpired
        case .tooEarly: RecoveryStrings.recoverCodeEarlyUnknown
        case .gone: RecoveryStrings.recoverCodeGone
        case .attestation: RecoveryStrings.recoverCodeAttestation
        case .retry: RecoveryStrings.recoverCodeRetry
        case .notACode: RecoveryStrings.recoverScanNotCode
        case .otherEnvironment: RecoveryStrings.recoverScanOtherEnvironment(s.otherApi ?? "")
        case .noApi: RecoveryStrings.recoverScanNoApi
        case .notAvailable: RecoveryStrings.recoverNotAvailable(TimeScales.text(TimeScales.recoveryDelay, by: timeScale))
        case .notOffered: RecoveryStrings.recoverNotOffered
        }
    }

    /// The text for ``RecoverState/typedProblem``; a refused character names the group to look at.
    static func typedProblem(_ s: RecoverState) -> String? {
        guard let problem = s.typedProblem else { return nil }
        let text = switch problem {
        case .letterU: RecoveryStrings.recoverTypeLetterU
        case .otherCharacter: RecoveryStrings.recoverTypeOtherCharacter
        case .badCheck: RecoveryStrings.recoverTypeBadCheck(s.accountHost)
        case .shortCode: RecoveryStrings.recoverTypeShortCode
        case .incomplete: RecoveryStrings.recoverTypeIncomplete
        }
        let refusedCharacter = problem == .letterU || problem == .otherCharacter
        return refusedCharacter && s.typedGroup > 0 ? RecoveryStrings.recoverTypeInGroup(text, s.typedGroup) : text
    }

    /// `retry_at` as the answers say it: the date and time in the phone's zone and language ("" without one).
    static func retryAt(_ date: Date?, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let date else { return "" }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone))
    }

    /// An answer of the table (one line per answer); [retryAt] is ``retryAt(_:locale:timeZone:)`` of the outcome's date.
    static func openAnswer(_ t: OpenAnswerText, retryAt: String) -> String { // swiftlint:disable:this cyclomatic_complexity
        let n = t.number ?? 0
        return switch t.key {
        case .rightIncomplete: RecoveryOpenStrings.onboardingOpenRightIncomplete(n, retryAt)
        case .wrongWait: RecoveryOpenStrings.onboardingOpenWrongWait(n, retryAt)
        case .wrong: RecoveryOpenStrings.onboardingOpenWrong(n)
        case .wrongAgain: RecoveryOpenStrings.onboardingOpenWrongAgain
        case .attemptLost: RecoveryOpenStrings.onboardingOpenAttemptLost(n)
        case .quiet: RecoveryOpenStrings.onboardingOpenQuiet(retryAt)
        case .quietNoDate: RecoveryOpenStrings.onboardingOpenQuietNodate
        case .quietNothing: RecoveryOpenStrings.onboardingOpenQuietNothing(retryAt)
        case .quietUsed: RecoveryOpenStrings.onboardingOpenQuietUsed(n)
        case .wait: RecoveryOpenStrings.onboardingOpenWait(retryAt)
        case .waitNoDate: RecoveryOpenStrings.onboardingOpenWaitNodate
        case .waitNothing: RecoveryOpenStrings.onboardingOpenWaitNothing(retryAt)
        case .busy: RecoveryOpenStrings.onboardingOpenBusy
        case .retry: RecoveryOpenStrings.onboardingOpenRetry
        case .retryUsed: RecoveryOpenStrings.onboardingOpenRetryUsed(n)
        case .storedMismatch: RecoveryOpenStrings.onboardingOpenStoredMismatch
        case .storedMismatchRight: RecoveryOpenStrings.onboardingOpenStoredMismatchRight
        case .exhausted: RecoveryOpenStrings.onboardingOpenExhausted
        case .closed: RecoveryOpenStrings.onboardingOpenClosed
        case .notArmed: RecoveryOpenStrings.onboardingOpenNotArmed
        case .counterUnavailable: RecoveryOpenStrings.onboardingOpenCounterUnavailable
        case .ok: RecoveryOpenStrings.onboardingOpenOk(n)
        case .okPlain: RecoveryOpenStrings.onboardingOpenOkPlain
        case .noRecovery: RecoveryOpenStrings.onboardingOpenNoRecovery
        case .noRecoveryUnanswered: RecoveryOpenStrings.onboardingOpenNoRecoveryUnanswered
        case .expired: RecoveryOpenStrings.onboardingOpenExpired
        case .attestation: RecoveryOpenStrings.onboardingOpenAttestation
        case .manifest: RecoveryOpenStrings.onboardingOpenManifest
        case .wrongRelease: RecoveryOpenStrings.onboardingOpenWrongRelease
        case .badRequest: RecoveryOpenStrings.onboardingOpenBadRequest
        case .other: RecoveryOpenStrings.onboardingOpenOther(t.code ?? "")
        case .finishBadPin: RecoveryOpenStrings.onboardingOpenFinishBadPin
        case .finishBackoff: RecoveryOpenStrings.onboardingOpenFinishBackoff
        case .lostNotHere: RecoveryOpenStrings.onboardingOpenLostNotHere
        case .finishFailed: RecoveryOpenStrings.onboardingOpenFinishFailed
        }
    }

    /// The warning before a send. The second attempt's: in real time (production, and every vault at scale 1) the approved
    /// words ("you can try again in 24 hours", the wait after a wrong second attempt, W(2) = one wait unit of 86,400 s); on a
    /// vault with a time scale (staging) the wait as it runs there (``recoveryWaitUnitScaledSeconds``), with the staging note
    /// (STAGING-TIME-SCALE §5.2: no text hard-codes "24 hours" for a wait a staging vault shortens).
    static func openWarning(_ w: OpenWarning, used: Int?, timeScale: UInt64) -> String {
        switch w {
        case .second:
            if timeScale <= 1 { return RecoveryOpenStrings.onboardingOpenSecond }
            let text = RecoveryOpenStrings.onboardingOpenSecondScaled(DurationText.of(recoveryWaitUnitScaledSeconds))
            return TimeScales.stagingNote(timeScale).map { text + "\n\n" + $0 } ?? text
        case .fewLeft:
            return RecoveryOpenStrings.onboardingOpenFewLeft(RecoveryOpenOutcome.attempts - (used ?? 0))
        }
    }
}
