import Foundation

// The states of a call and the times the state machine keeps. Mirrors vettid-android `CallState.kt`.

public enum CallDirection: Sendable { case outgoing, incoming }

/// Where a live call stands.
public enum CallPhase: Sendable {
    /// Outgoing: the offer is being made and sent to this member's vault.
    case starting
    /// Outgoing: the vault has sent the offer on.
    case calling
    /// Outgoing: the other member's device is ringing.
    case ringing
    /// Incoming: ringing here.
    case incoming
    /// Answered: the two devices are finding a path.
    case connecting
    /// Media flows, encrypted under the call's keys.
    case active
}

/// Why a call ended. One text per value in the screens.
public enum CallEnd: Sendable, CaseIterable {
    /// This member hung up.
    case hungUp
    /// The other member hung up.
    case peerHungUp
    /// The other member declined.
    case declined
    /// Declined here (on this device or another of the member's).
    case declinedHere
    /// The other member is on another call (or both called each other at once).
    case busy
    /// Nobody answered within the ring time.
    case noAnswer
    /// An incoming call that stopped before it was answered.
    case missed
    /// Answered on another of the member's devices.
    case answeredElsewhere
    /// The connection or the call is no longer there.
    case unavailable
    /// This member's vault is already in a call.
    case ownVaultBusy
    /// (C2) The member turned calls with this connection off (perhaps on another device a moment before): `calls_off`.
    case callsOff
    /// The daily owner check is due: no calls until it is done.
    case ownerCheckRequired
    /// This vault's release has no calls.
    case notSupported
    /// This device found no network address to be reached at (for example a blocked network permission).
    case noAddress
    /// The two devices found no path to each other within 60 s.
    case couldNotConnect
    /// The path was lost during the call.
    case connectionLost
    /// The call could not be encrypted: keys, suites or frames did not check out. Nothing unencrypted was played.
    case notEncrypted
    /// The vault was locked.
    case locked
    /// Anything else.
    case failed
}

public enum CallState: Equatable, Sendable {
    case idle
    case live(Live)
    /// The last call, until it is dismissed or another begins.
    case ended(Ended)

    public struct Live: Equatable, Sendable {
        public var connectionId: String
        public var direction: CallDirection
        public var phase: CallPhase
        /// Nil while an outgoing call is ``CallPhase/starting``.
        public var callId: String?
        public var muted: Bool
        /// When media first flowed.
        public var activeSince: Date?
        /// Active, but the path is interrupted; the media stack is trying to get it back.
        public var reconnecting: Bool
        /// (C2) This device's side of the answer is through: the callee's `call.answer` is with its vault, or the caller has
        /// taken the answer. From then the call is `active` in the vault, and keep-alives may go (VAULT-MESSAGING "Liveness");
        /// one before it is answered `call.end{unavailable}`.
        public var answerThrough: Bool
        /// (C2) The call is in form 2: placed in form 2, or answering an offer in form 2. That proves the vault C2 for this
        /// call, whatever the `call.list` probe has found yet: keep-alives go on it.
        public var formTwo: Bool

        public init(
            connectionId: String, direction: CallDirection, phase: CallPhase, callId: String? = nil, muted: Bool = false,
            activeSince: Date? = nil, reconnecting: Bool = false, answerThrough: Bool = false, formTwo: Bool = false
        ) {
            self.connectionId = connectionId
            self.direction = direction
            self.phase = phase
            self.callId = callId
            self.muted = muted
            self.activeSince = activeSince
            self.reconnecting = reconnecting
            self.answerThrough = answerThrough
            self.formTwo = formTwo
        }
    }

    public struct Ended: Equatable, Sendable {
        public var connectionId: String
        public var direction: CallDirection
        public var reason: CallEnd
        public var callId: String?
        /// How long media flowed; nil if it never did.
        public var duration: Duration?

        public init(connectionId: String, direction: CallDirection, reason: CallEnd, callId: String? = nil, duration: Duration? = nil) {
            self.connectionId = connectionId
            self.direction = direction
            self.reason = reason
            self.callId = callId
            self.duration = duration
        }
    }
}

/// Measurements of a call, for the diagnostics view and the phone tests. No identifiers, nothing secret.
public struct CallDiagnostics: Equatable, Sendable {
    /// Outgoing: from the tap on Call to the vault's answer to `call.start`.
    public var tapToPlacedMs: Int64?
    /// Outgoing: from the tap on Call to `call.ringing` (the other phone rings). CALLS-PLAN §7 measures this.
    public var tapToRingingMs: Int64?
    /// From the answer (tapped here, or received) to the first media.
    public var answerToMediaMs: Int64?
    public var media: MediaDiagnostics?

    public init(tapToPlacedMs: Int64? = nil, tapToRingingMs: Int64? = nil, answerToMediaMs: Int64? = nil, media: MediaDiagnostics? = nil) {
        self.tapToPlacedMs = tapToPlacedMs
        self.tapToRingingMs = tapToRingingMs
        self.answerToMediaMs = answerToMediaMs
        self.media = media
    }
}

/// (C2; CALLS-PLAN §7 C5: "the app records direct or relayed per call, locally") How the calls that connected since the
/// process started went: directly between the two phones, through a relay, or not known (the stack never said). Three
/// counts and nothing else (no call id, address or time), in memory for the life of the process.
public struct CallPaths: Equatable, Sendable {
    public var direct: Int
    public var relayed: Int
    public var unknown: Int

    public init(direct: Int = 0, relayed: Int = 0, unknown: Int = 0) {
        self.direct = direct
        self.relayed = relayed
        self.unknown = unknown
    }
}

/// The times the state machine keeps. Defaults are the plan's; tests shorten nothing (virtual time).
public struct CallTimings: Sendable {
    /// No address gathered after this long: the call ends ``CallEnd/noAddress``.
    public var gather: Duration
    /// No media this long after the answer: the call ends ``CallEnd/couldNotConnect``. 60 s (owner decision 2026-11-11,
    /// VAULT-MESSAGING 0.88.16): a slow path (TURN, a network allowing only TCP 443) may take a while.
    public var connect: Duration
    /// (C2) The answering device, its microphone held back, ends the call as not encrypted when no frame has decrypted this
    /// long after its connection is established (VAULT-MESSAGING "Key confirmation").
    public var decrypt: Duration
    /// The caller rings for the offer's lifetime, kept within these bounds whatever the two clocks say.
    public var minRing: Duration
    public var maxRing: Duration
    /// A callee stops ringing this long after the offer's `exp` if the caller's `call.end` has not come.
    public var incomingGrace: Duration
    public var maxIncomingRing: Duration
    /// Local candidates wait this long to be sent together.
    public var iceBatch: Duration
    /// At most one `call.ice` per interval (the relay takes 5 deposits a second from one sender).
    public var iceInterval: Duration
    /// `call.ice` messages this device sends for one call (a vault forwards 256, both directions together).
    public var maxIceMessages: Int
    public var diagnosticsEvery: Duration
    /// The pause before the vault's call events are listened to again after the listening ended.
    public var relisten: Duration

    public init(
        gather: Duration = .seconds(8), connect: Duration = .seconds(60), decrypt: Duration = .seconds(20),
        minRing: Duration = .seconds(10), maxRing: Duration = .seconds(60), incomingGrace: Duration = .seconds(3),
        maxIncomingRing: Duration = .seconds(93), iceBatch: Duration = .milliseconds(200), iceInterval: Duration = .milliseconds(300),
        maxIceMessages: Int = 100, diagnosticsEvery: Duration = .seconds(1), relisten: Duration = .seconds(1)
    ) {
        self.gather = gather
        self.connect = connect
        self.decrypt = decrypt
        self.minRing = minRing
        self.maxRing = maxRing
        self.incomingGrace = incomingGrace
        self.maxIncomingRing = maxIncomingRing
        self.iceBatch = iceBatch
        self.iceInterval = iceInterval
        self.maxIceMessages = maxIceMessages
        self.diagnosticsEvery = diagnosticsEvery
        self.relisten = relisten
    }
}

extension Duration {
    /// Whole milliseconds (rounded down).
    var wholeMilliseconds: Int64 {
        let c = components
        return c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000
    }

    /// The span of [seconds], rounded to the millisecond (two instants of a clock that counts in milliseconds are exact).
    static func rounded(seconds: TimeInterval) -> Duration { .milliseconds(Int64((seconds * 1000).rounded())) }
}
