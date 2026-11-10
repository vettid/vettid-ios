import Foundation
import VettIDCrypto
import VettIDVault

/// What this phone pairs (`device.pair.create{role}`, VAULT-MESSAGING §10.3): an agent, or (owner decision 2026-11-05, vettid-android
/// #291, reversing ANDROID-PLAN decision 9) a desktop. ``wire`` is the role as the vault says it in `device.pair.create` and
/// `device.pair.pending`; ``kind`` is the `t` of the link (`a` or `d`, §6.7.1), which must match the role or the code is never shown.
/// Mirrors vettid-android `PairRole`.
public enum PairRole: Sendable, Equatable {
    case agent, desktop

    public var wire: String {
        switch self {
        case .agent: "agent"
        case .desktop: "desktop"
        }
    }

    public var kind: InviteKind {
        switch self {
        case .agent: .agent
        case .desktop: .desktop
        }
    }

    /// Whether [d] is a device of this role (this phone is neither).
    func matches(_ d: DeviceInfo) -> Bool {
        switch self {
        case .agent: d.isAgent
        case .desktop: !d.thisPhone && d.kind == DeviceInfo.kindDesktop
        }
    }
}

/// A pairing code the vault made for an agent or a desktop (`device.pair.create`): ``link`` is the bare pairing payload, a bearer
/// secret for its few minutes (VAULT-MESSAGING §6.4; ANDROID-PLAN 0.1.53 AA2). Its text form, its dump and its mirror never carry
/// the link. Mirrors vettid-android `PairingCode`.
public struct PairingCode: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let pairingID: String
    public let link: String
    public let exp: Date

    public init(pairingID: String, link: String, exp: Date) {
        self.pairingID = pairingID
        self.link = link
        self.exp = exp
    }

    public var description: String { "PairingCode(exp: \(exp))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A pairing the new device has answered (`device.pair.pending`): what the member compares. ``name`` is what the device says about
/// itself, cleaned (never trusted); ``sas`` is the six digits, or nil when the event did not carry six digits or was not for the
/// role this phone made the code for, so that it cannot be compared and only rejected. ``ends`` is when this phone stops offering
/// the approval (10 minutes after the event). Held in memory only; never printed, dumped or mirrored. Mirrors vettid-android
/// `PendingPairing`.
public struct PendingPairing: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let pairingID: String
    public let name: String
    public let sas: String?
    public let ends: Date

    public init(pairingID: String, name: String, sas: String?, ends: Date) {
        self.pairingID = pairingID
        self.name = name
        self.sas = sas
        self.ends = ends
    }

    /// An approval is offered only for a code that can be compared.
    public var comparable: Bool { sas != nil }

    public var description: String { "PendingPairing(ends: \(ends))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Where a pairing is (ANDROID-PLAN 0.1.53 AA2). Held in memory only. Mirrors vettid-android `PairingStage`.
public enum PairingStage: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Nothing held.
    case idle
    /// `device.pair.create` is on its way.
    case creating
    /// Step 1: the code is shown.
    case code(PairingCode)
    /// The code expired unused: nothing was paired. The pairing's id and end are kept, only to take a late answer of the device (a
    /// pending up to ``lateSeconds`` after [exp]); the code itself is gone, and the comparison is still required.
    case codeExpired(pairingID: String, exp: Date)
    /// Step 2: the new device has answered; the member compares the code.
    case compare(PendingPairing)
    /// The member rejected it. [told]: the vault took the rejection (the device is told); false when the request failed.
    case rejected(told: Bool)
    /// The approval went through. [deviceID] is the new device's id when known (nil: the list opens instead).
    case paired(name: String, deviceID: String?)
    /// The pairing ended without an approval (its time ran out, or the vault refused the approval): nothing is paired.
    case ended

    /// How long after a code expired the device's late answer is still taken.
    public static let lateSeconds: TimeInterval = 60

    // The stage names, never what it holds (a code, a name).
    public var description: String {
        switch self {
        case .idle: "idle"
        case .creating: "creating"
        case .code: "code"
        case .codeExpired: "codeExpired"
        case .compare: "compare"
        case .rejected(let told): "rejected(told: \(told))"
        case .paired: "paired"
        case .ended: "ended"
        }
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The pairing as the screen sees it: the stage, a request in flight, and the last request's failure. Mirrors vettid-android
/// `PairingState`.
public struct PairingState: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var stage = PairingStage.idle
    public var busy = false
    public var error: FailureKind?
    /// With ``PairingStage/ended``: the approval's outcome is unknown (no answer), so the device may be in the list.
    public var unknownOutcome = false
    /// With ``unknownOutcome``: the name the device gave itself (cleaned), for "If <name> is listed…".
    public var agentName: String?
    /// What this pairing is for: the screens say "agent" or "desktop" by it. Set by ``PairingManager/start(_:owner:)``.
    public var role = PairRole.agent
    /// Which pairing this state is of: the manager's generation when it was published (it moves with every start, lock and
    /// cancellation). A screen keeps the one it saw and leaves only that pairing (``PairingRepository/leave(token:owner:)``), so a late
    /// leave of an old screen never reaches the pairing of a newer one. Not part of equality.
    public var token = 0

    public init(
        stage: PairingStage = .idle, busy: Bool = false, error: FailureKind? = nil, unknownOutcome: Bool = false,
        agentName: String? = nil, role: PairRole = .agent
    ) {
        self.stage = stage
        self.busy = busy
        self.error = error
        self.unknownOutcome = unknownOutcome
        self.agentName = agentName
        self.role = role
    }

    public var description: String {
        "PairingState(stage: \(stage), busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"), role: \(role.wire))"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Equality leaves out ``PairingState/token``: a screen following the state sees a change of pairing by the stage (a new pairing starts
/// at `.creating`, and every end passes through `.idle` or a final stage), never by the token alone with the same stage holding the
/// same pairing, so nothing it follows is missed.
extension PairingState: Equatable {
    public static func == (a: PairingState, b: PairingState) -> Bool {
        a.stage == b.stage && a.busy == b.busy && a.error == b.error && a.unknownOutcome == b.unknownOutcome &&
            a.agentName == b.agentName && a.role == b.role
    }
}
