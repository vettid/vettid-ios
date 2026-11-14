import Foundation
import VettIDCrypto
import VettIDVault

// What the call state machine needs of the vault (VAULT-MESSAGING §10.10), so that it can be tested without one. Mirrors
// vettid-android `CallSignalling.kt`.

/// The two frame keys of a call on their way from the signalling to the media engine, which wipes the copies it is given.
/// The keys are held here until ``wipe()``, which overwrites them in place.
package final class MediaKeys: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    package let suite: MediaSuite
    private let lock = NSLock()
    private var sendKey: [UInt8]
    private var receiveKey: [UInt8]

    package init(suite: MediaSuite, send: [UInt8], receive: [UInt8]) {
        self.suite = suite
        sendKey = send
        receiveKey = receive
    }

    deinit { wipe() }

    /// A copy of the key for this device's sender; the one who takes it wipes it after use.
    package var send: [UInt8] { lock.withLock { sendKey } }

    /// A copy of the key for this device's receiver.
    package var receive: [UInt8] { lock.withLock { receiveKey } }

    package func wipe() {
        lock.withLock {
            Bytes.wipe(&sendKey)
            Bytes.wipe(&receiveKey)
        }
    }

    package var description: String { "MediaKeys(suite=\(suite.id), [redacted])" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The vault's answer to `call.start`.
package struct PlacedCall: Sendable {
    package let callId: String
    /// When the offer expires, by the vault's clock.
    package let exp: Date
    /// The servers the vault signed for this call, and the only ones the device may use.
    package let servers: [CallWire.IceServer]
    /// (C2) Placed in form 2.
    package let formTwo: Bool

    package init(callId: String, exp: Date, servers: [CallWire.IceServer] = [], formTwo: Bool = false) {
        self.callId = callId
        self.exp = exp
        self.servers = servers
        self.formTwo = formTwo
    }
}

/// The vault refused `call.start` with ``code`` (`busy`, `not_found`, `owner_check_required`, `unsupported_type`, ...).
package struct CallRefusedError: Error, Equatable, Sendable, CustomStringConvertible {
    package let code: String

    package init(code: String) { self.code = code }

    package var description: String { "call refused: \(code)" }
}

/// The call cannot be made secure: a key-exchange share, an ICE configuration or a media suite that does not check out, or
/// no suite in common. The call ends; nothing of the message is used.
package struct CallSecurityError: Error, Equatable, Sendable, CustomStringConvertible {
    package let what: String

    package init(_ what: String) { self.what = what }

    package var description: String { "call not secure: \(what)" }
}

/// An incoming offer, **already verified** (signatures, suites). It holds an SDP and server credentials: ``description``
/// shows neither.
package struct CallOffer: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    package let callId: String
    package let connectionId: String
    /// The caller's SDP offer, ready for the media engine.
    package let sdp: String
    package let exp: Date
    /// How long to ring: the offer's lifetime by the vault's clock, not this phone's.
    package let ringFor: Duration
    package let servers: [CallWire.IceServer]
    /// The suite this device will answer with, chosen when the offer was checked: the engine is made for it.
    package let suite: MediaSuite
    /// (C2) The offer carried form 2, so this device answers in form 2 (and holds its media until a frame decrypts).
    package let formTwo: Bool

    package init(
        callId: String, connectionId: String, sdp: String, exp: Date, ringFor: Duration, servers: [CallWire.IceServer],
        suite: MediaSuite, formTwo: Bool = false
    ) {
        self.callId = callId
        self.connectionId = connectionId
        self.sdp = sdp
        self.exp = exp
        self.ringFor = ringFor
        self.servers = servers
        self.suite = suite
        self.formTwo = formTwo
    }

    package var description: String { "Offer(\(callId))" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The callee's answer, verified: its SDP and this call's keys.
package struct CallAnswer: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    package let callId: String
    package let sdp: String
    package let keys: MediaKeys

    package init(callId: String, sdp: String, keys: MediaKeys) {
        self.callId = callId
        self.sdp = sdp
        self.keys = keys
    }

    package var description: String { "Answer(\(callId))" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What reaches the call from the vault. Offers and answers arrive here **already verified** (signatures, suites).
package enum SignalEvent: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case offer(CallOffer)
    /// The callee's device is ringing.
    case ringing(callId: String)
    case answer(CallAnswer)
    /// An answer arrived that does not verify: the call must not go on.
    case answerRejected(callId: String)
    case ice(callId: String, candidates: [CallCandidate])
    /// [supersededBy] (C2, "Glare"): the call that won over this device's own outgoing call to the same connection.
    case end(callId: String, reason: String, supersededBy: String? = nil)

    /// No SDP (it holds addresses), no server credentials, no candidates.
    package var description: String {
        switch self {
        case .offer(let o): o.description
        case .ringing(let id): "Ringing(\(id))"
        case .answer(let a): a.description
        case .answerRejected(let id): "AnswerRejected(\(id))"
        case .ice(let id, let c): "Ice(\(id), \(c.count))"
        case .end(let id, let reason, let by): "End(\(id), \(reason), \(by ?? "nil"))"
        }
    }

    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What the call state machine needs of the vault (VAULT-MESSAGING §10.10). The implementation over `VaultApi` keeps each
/// call's key material, verifies everything before it reaches ``events()``, and negotiates the media suite from the engine's
/// ``MediaEngine/suites``.
///
/// Package-internal: ``CallMachine`` trusts what this gives it, so there is one implementation outside tests,
/// ``VaultCallSignalling``, and no other package can add a second.
@MainActor
package protocol CallSignalling: AnyObject {
    /// The vault's call events, verified. Asked for again each time the listening has ended.
    func events() -> AsyncThrowingStream<SignalEvent, Error>

    /// What a `call.start` offers of [suites], the preferred one first: the caller's engine is made for the first. Form 1
    /// only: suite 1 (``MediaSuite/formOne(_:)``). That holds for **every** `call.start` that carries a form 1 signature, a
    /// C2 start that also carries form 2 included: no second suite is offered while any `call.start` carries form 1, i.e.
    /// until form 1 is retired (VAULT-MESSAGING §10.10 "Call forms" rule 3, "Mixed releases").
    func offerable(_ suites: [MediaSuite]) -> [MediaSuite]

    /// `call.start`. Throws ``CallRefusedError`` with the vault's code, ``CallSecurityError``, or another error.
    func start(connectionId: String, sdp: String, suites: [MediaSuite]) async throws -> PlacedCall

    /// `call.answer` for a verified offer: returns the call's keys. Throws ``CallSecurityError`` or another error.
    func answer(callId: String, sdp: String, suites: [MediaSuite]) async throws -> MediaKeys

    /// `call.ringing`.
    func ringing(callId: String) async throws

    /// `call.ice`: at most 16 candidates.
    func ice(callId: String, candidates: [CallCandidate]) async throws

    /// `call.end` (durable).
    func end(callId: String, reason: String) async throws

    /// (C2) `call.keepalive` for the active call [callId], while the vault is C2 ([formTwo]).
    func keepalive(callId: String) async throws

    /// (C2) Whether this device's vault is C2 (`call.list` `v: 2`): form 2, keep-alives.
    var formTwo: Bool { get }
}

extension CallSignalling {
    package func offerable(_ suites: [MediaSuite]) -> [MediaSuite] { MediaSuite.formOne(suites) }
    package func keepalive(callId: String) async throws {}
    /// Always false in C1: ``VaultCallSignalling`` is form 1 only.
    package var formTwo: Bool { false }
}
