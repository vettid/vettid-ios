import Foundation
import VettIDData

/// What a pairing step says: its title, its body line and its two buttons' labels (nil: no such button), as a screen of vettid-android's
/// `PairScreen` puts them. The screen takes its words from here (``PairTexts/step(_:)``), so that they are tested without a screen.
public struct PairStep: Equatable, Sendable {
    public var title: String
    public var body: String?
    public var primary: String?
    public var secondary: String?
    /// The primary button is in the error colour: a pairing that can only be rejected.
    public var destructive = false
}

/// How the pairing screens say what is happening (ANDROID-PLAN 0.1.53 AA2; "Pair a desktop", vettid-android #291): the agent's words, or the
/// desktop's where the role is a desktop's. A device's name is its own word about itself, cleaned and isolated (never trusted), and
/// a failure of the ``ended`` stage never names a code. Mirrors the choices inside vettid-android `PairScreen`.
public enum PairTexts {
    /// The words of the stage [s] is at, for the role it is for.
    public static func step(_ s: PairState) -> PairStep {
        let desktop = s.pairing.role == .desktop
        let title = desktop ? DeviceStrings.pairTitleDesktop : DeviceStrings.pairTitle
        switch s.stage {
        case .code:
            let body = desktop ? DeviceStrings.pairCodeBodyDesktop : DeviceStrings.pairCodeBody
            return PairStep(title: title, body: body, secondary: DeviceStrings.pairCancel)
        case .codeExpired:
            return PairStep(
                title: title, body: DeviceStrings.pairExpired, primary: DeviceStrings.pairNewCode, secondary: DeviceStrings.pairCancel
            )
        case .compare(let p):
            // A pairing that cannot be compared (no six digits, or not this role's) offers only Reject.
            let comparable = p.comparable
            return PairStep(
                title: DeviceStrings.pairCompareTitle, primary: comparable ? DeviceStrings.pairCodesMatch : DeviceStrings.pairReject,
                secondary: comparable ? DeviceStrings.pairCodesDiffer : nil, destructive: !comparable
            )
        case .rejected(let told):
            return PairStep(
                title: DeviceStrings.pairRejectedTitle, body: rejected(told: told, desktop: desktop), primary: DeviceStrings.pairDone
            )
        case .paired(let name, let deviceID):
            return paired(name: name, deviceID: deviceID, desktop: desktop)
        case .ended:
            return ended(s, desktop: desktop)
        case .idle where s.interrupted:
            // A lock or a hold took the pairing away while the screen was open: it was interrupted, nothing is paired.
            return PairStep(
                title: DeviceStrings.pairEndedTitle, body: DeviceStrings.pairEnded, primary: DeviceStrings.pairNewCode,
                secondary: DeviceStrings.pairCancel
            )
        case .idle where s.pairing.error != nil:
            // The daily check's notice is the vault's own words (the screen adds it); any other failure is the plain one.
            let body = s.pairing.error == .ownerCheckRequired ? nil : DeviceStrings.pairCreateFailed
            return PairStep(title: title, body: body, primary: DeviceStrings.pairTryAgain, secondary: DeviceStrings.pairCancel)
        case .idle where s.held:
            return PairStep(title: DeviceStrings.pairLostTitle, body: DeviceStrings.pairLostBody, primary: DeviceStrings.pairDone)
        case .idle, .creating:
            return PairStep(title: title)
        }
    }

    /// A desktop gets no rules or permissions (it asks for access sessions, which come to Approvals): only Done. An agent can be
    /// taken to its page when its id is known.
    private static func paired(name: String, deviceID: String?, desktop: Bool) -> PairStep {
        PairStep(
            title: DeviceStrings.pairPairedTitle(desktop ? DeviceTexts.titleDesktop(name) : DeviceTexts.titleAgent(name)),
            body: desktop ? DeviceStrings.pairPairedBodyDesktop : DeviceStrings.pairPairedBody, primary: DeviceStrings.pairDone,
            secondary: !desktop && deviceID != nil ? DeviceStrings.pairOpenPage : nil
        )
    }

    /// No answer from the vault asserts nothing: not "Not paired", but that it was not confirmed.
    private static func ended(_ s: PairState, desktop: Bool) -> PairStep {
        guard s.pairing.unknownOutcome else {
            return PairStep(title: DeviceStrings.pairEndedTitle, body: DeviceStrings.pairEnded, primary: DeviceStrings.pairDone)
        }
        let name = s.pairing.agentName ?? ""
        return PairStep(
            title: DeviceStrings.pairUnconfirmedTitle,
            body: DeviceStrings.pairUnconfirmedBody(desktop ? DeviceTexts.sentenceDesktop(name) : DeviceTexts.sentenceAgent(name)),
            primary: DeviceStrings.pairDone
        )
    }

    /// What a rejection says: that the vault could not be told, else that the agent (or desktop) is told.
    public static func rejected(told: Bool, desktop: Bool) -> String {
        if !told { return DeviceStrings.pairRejectedUnsent }
        return desktop ? DeviceStrings.pairRejectedBodyDesktop : DeviceStrings.pairRejectedBody
    }

    /// "Does the agent show 123 456? Approve only if the codes match.": the digits in two groups of three.
    public static func compareBody(sas: String, desktop: Bool) -> String {
        let grouped = "\(sas.prefix(3)) \(sas.dropFirst(3))"
        return desktop ? DeviceStrings.pairCompareBodyDesktop(grouped) : DeviceStrings.pairCompareBody(grouped)
    }

    /// "It calls itself <name>.": the name cleaned and isolated, "an agent" or "a desktop" when it gave none.
    public static func callsItself(_ name: String, desktop: Bool) -> String {
        DeviceStrings.pairCallsItself(desktop ? DeviceTexts.sentenceDesktop(name) : DeviceTexts.sentenceAgent(name))
    }

    /// The note under it: that the name is only what the device says about itself.
    public static func callsItselfNote(desktop: Bool) -> String {
        desktop ? DeviceStrings.pairCallsItselfNoteDesktop : DeviceStrings.pairCallsItselfNote
    }

    /// The sheet's sentence under "Allow access now?".
    public static func allowBody(desktop: Bool) -> String { desktop ? DeviceStrings.pairAllowBodyDesktop : DeviceStrings.pairAllowBody }

    /// A first access choice's label.
    public static func label(_ c: SessionChoice) -> String {
        switch c {
        case .none: DeviceStrings.pairSessionNone
        case .minutes15: DeviceStrings.pairSession15m
        case .hour1: DeviceStrings.pairSession1h
        case .hours4: DeviceStrings.pairSession4h
        case .hours8: DeviceStrings.pairSession8h
        case .hours24: DeviceStrings.pairSession24h
        }
    }
}
