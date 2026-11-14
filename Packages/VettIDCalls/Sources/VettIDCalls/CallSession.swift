import Foundation
import VettIDVault

/// Everything that goes through the state machine's one queue.
enum CallMessage: Sendable {
    case call(connectionId: String)
    case answer
    case decline
    case hangUp(CallEnd)
    case endQuietly(CallEnd)
    case mute(Bool)
    case dismiss
    case signal(SignalEvent)
    case media(seq: Int, MediaEvent)
    case placed(seq: Int, PlacedCall, atMs: Int64)
    case answered(seq: Int)
    case remoteApplied(seq: Int)
    case gathering(seq: Int)
    case failed(seq: Int, CallEnd)
    case timer(seq: Int, TimerKind)
    case path(seq: Int, relayed: Bool)
}

enum TimerKind: Sendable { case ringOut, ringIn, gather, connect, decrypt, iceFlush }

/// One piece of the engine's work, run in order with the others of its call.
typealias LaneWork = @MainActor () async throws -> Void

/// One call's working state. Touched only by the machine's loop; the call's own tasks report back through the queue.
@MainActor
final class CallSession {
    let seq: Int
    let connectionId: String
    let direction: CallDirection
    let tappedAtMs: Int64
    var engine: (any MediaEngine)?
    var callId: String?
    var phase: CallPhase = .starting
    var offer: CallOffer?
    var muted = false
    var activeSince: Date?
    var reconnecting = false
    var keysSet = false

    /// (C2) The answering device's outgoing track is held until its receiver first decrypts a frame.
    var heldForDecrypt = false
    /// (C2) The call is in form 2: placed in form 2, or answering a form 2 offer.
    var formTwo = false
    var remoteApplied = false
    var canSendIce = false
    var gathered = 0
    var iceMessages = 0
    var flushScheduled = false
    var answeredAtMs: Int64?

    /// (C2, VAULT-MESSAGING §10.10 "Glare") This outgoing call lost a glare to the connection's call with this id: the vault
    /// ended it (nothing more is sent for it) and rings for that call next, which this device answers without asking as soon
    /// as its offer is here; until then the call screen stays as it was, and the ring timer still bounds the wait (then it
    /// shows busy, as before C2).
    var supersededBy: String?

    /// This member ended the call here (a hang-up, a decline, a lock): the connection's held offer is then not rung, since a
    /// call rings only while the vault is open and the member has just said no.
    var memberEnded = false

    /// The connection's own offer that arrived while this outgoing call rang to it (a glare's winner, perhaps).
    var glareOffer: CallOffer?

    /// The last path the stack reported for this call (relayed or direct); nil while it has said nothing.
    var relayed: Bool?

    /// The answer's keys until the engine has them (it wipes its copies); wiped here if the call ends first.
    var keys: MediaKeys?

    /// What the vault passed on for this call before its answer to `call.start` was handled here (the answer and the events
    /// come through two queues: a `call.end{busy}` or even a `call.answer` can be first). Held while the call has no id, and
    /// handled in order once it has.
    var early: [SignalEvent] = []
    var pendingRemote: [CallCandidate] = []
    var pendingLocal: [CallCandidate] = []
    var timers: [TimerKind: Task<Void, Never>] = [:]

    private var tasks: [Task<Void, Never>] = []
    private var closed = false
    private var laneOpen = true
    private let laneIn: AsyncStream<LaneWork>.Continuation
    let lane: AsyncStream<LaneWork>

    init(seq: Int, connectionId: String, direction: CallDirection, tappedAtMs: Int64) {
        self.seq = seq
        self.connectionId = connectionId
        self.direction = direction
        self.tappedAtMs = tappedAtMs
        (lane, laneIn) = AsyncStream.makeStream(of: LaneWork.self)
    }

    /// Runs [body] as one of this call's tasks: cancelled with the call. Nothing is started for a call that is over.
    @discardableResult
    func launch(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !closed else { return nil }
        let t = Task { await body() }
        tasks.append(t)
        return t
    }

    /// Queues engine work, which runs in order.
    func enqueue(_ work: @escaping LaneWork) {
        if laneOpen { laneIn.yield(work) }
    }

    /// Drops what is queued and takes no more (a call that lost a glare has let its media go).
    func dropLane() {
        laneOpen = false
        laneIn.finish()
    }

    var laneIsOpen: Bool { laneOpen }

    /// The call's tasks end with it.
    func cancelTasks() {
        closed = true
        dropLane()
        for t in tasks { t.cancel() }
        tasks.removeAll()
        for t in timers.values { t.cancel() }
        timers.removeAll()
    }
}
