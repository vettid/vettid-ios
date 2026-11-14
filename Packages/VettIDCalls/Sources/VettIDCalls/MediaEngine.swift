import Foundation
import VettIDCrypto
import VettIDVault

// The media of one call, behind a protocol so that the call state machine has no media stack in it. Mirrors vettid-android
// `MediaEngine.kt` and `MediaDiagnostics.kt` (the statistics reading is with the WebRTC engine, a later change).

/// Where the media connection of a call stands.
public enum MediaConnection: Sendable { case new, connecting, connected, disconnected, failed, closed }

/// The frame encryption of one direction, as the media stack reports it.
public enum CryptorState: Sendable {
    case new
    /// Frames are being encrypted or decrypted under the call's key.
    case ok
    /// No key is set: a sender sends nothing, a receiver plays nothing.
    case missingKey
    /// The receiver could not decrypt: wrong key, or frames that were not encrypted. It plays nothing from now on.
    case decryptionFailed
    case encryptionFailed
    case internalError
    /// A state this build does not know: treated as a failure.
    case unknown
}

public enum MediaDirection: Sendable { case send, receive }

/// What a ``MediaEngine`` tells the call. Nothing in an event is secret.
public enum MediaEvent: Sendable {
    /// One of this device's addresses, to be sent to the other device.
    case localCandidate(CallCandidate)
    /// Gathering has ended; [found] is how many addresses there were. None: this device cannot be reached.
    case gatheringDone(found: Int)
    case connection(MediaConnection)
    case cryptor(MediaDirection, CryptorState)
    /// The engine cannot go on ([what] is for diagnostics; never key material, never an address).
    case failed(String)
}

/// The engine found media that the call's frame encryption does not cover (a media section other than the one audio section
/// that carries the cryptors), or could not put the encryption in place. The call ends as not encrypted; nothing is played.
public struct MediaNotEncryptedError: Error, Equatable, Sendable, CustomStringConvertible {
    public let what: String

    public init(_ what: String) { self.what = what }

    public var description: String { "media not encrypted: \(what)" }
}

/// The media stack's own logging is on, or cannot be shown to be off: it is not used (it could print addresses or keys).
public struct MediaLoggingError: Error, Equatable, Sendable, CustomStringConvertible {
    public let what: String

    public init(_ what: String) { self.what = what }

    public var description: String { "media stack logging: \(what)" }
}

public struct CandidateInfo: Equatable, Sendable, CustomStringConvertible {
    public let type: String
    public let `protocol`: String
    public let network: String

    public init(type: String, protocol: String, network: String) {
        self.type = type
        self.protocol = `protocol`
        self.network = network
    }

    public var relayed: Bool { type == "relay" }

    public var description: String { [type, `protocol`, network].filter { !$0.isEmpty }.joined(separator: " / ") }
}

/// A reading of the media stack's statistics (no identifiers, nothing secret).
public struct MediaDiagnostics: Equatable, Sendable {
    public var micLevel: Double
    public var remoteLevel: Double
    public var packetsSent: Int64
    public var packetsReceived: Int64
    /// How many audio streams the receiver sees: a second one is RTP on an SSRC nobody announced.
    public var inboundAudioStreams: Int
    public var sendCodec: String
    public var receiveCodec: String
    public var local: CandidateInfo?
    public var remote: CandidateInfo?
    public var roundTripMs: Double?
    public var sendCryptor: CryptorState
    public var receiveCryptor: CryptorState

    public init(
        micLevel: Double = 0, remoteLevel: Double = 0, packetsSent: Int64 = 0, packetsReceived: Int64 = 0,
        inboundAudioStreams: Int = 0, sendCodec: String = "", receiveCodec: String = "", local: CandidateInfo? = nil,
        remote: CandidateInfo? = nil, roundTripMs: Double? = nil, sendCryptor: CryptorState = .new, receiveCryptor: CryptorState = .new
    ) {
        self.micLevel = micLevel
        self.remoteLevel = remoteLevel
        self.packetsSent = packetsSent
        self.packetsReceived = packetsReceived
        self.inboundAudioStreams = inboundAudioStreams
        self.sendCodec = sendCodec
        self.receiveCodec = receiveCodec
        self.local = local
        self.remote = remote
        self.roundTripMs = roundTripMs
        self.sendCryptor = sendCryptor
        self.receiveCryptor = receiveCryptor
    }

    /// Whether the path goes through a relay; nil while the stack has not said (either end unknown).
    public var relayed: Bool? {
        guard let local, let remote else { return nil }
        return local.relayed || remote.relayed
    }
}

/// FAULTS ON PURPOSE, for the two-phone tests only: each makes this device break one rule of the media rules (CALL-MEDIA §7),
/// so that the other device can be seen to refuse it. All off in every build a member uses.
public struct MediaFaults: Equatable, Sendable {
    /// Receiving: leave the other side's `a=ssrc` lines in.
    public var keepRemoteSsrc = false
    /// Sending: announce other SSRCs than the ones used, so that this device's audio arrives unsignalled.
    public var misstateOwnSsrc = false
    /// Sending: switch this device's sender cryptor off (clear frames).
    public var sendUnencrypted = false
    /// Sending: encrypt under a key that is not the call's.
    public var wrongSendKey = false

    public init(keepRemoteSsrc: Bool = false, misstateOwnSsrc: Bool = false, sendUnencrypted: Bool = false, wrongSendKey: Bool = false) {
        self.keepRemoteSsrc = keepRemoteSsrc
        self.misstateOwnSsrc = misstateOwnSsrc
        self.sendUnencrypted = sendUnencrypted
        self.wrongSendKey = wrongSendKey
    }

    public var any: Bool { keepRemoteSsrc || misstateOwnSsrc || sendUnencrypted || wrongSendKey }
}

/// How an engine is set up.
public struct MediaConfig: Equatable, Sendable {
    /// DEBUG BUILDS ONLY, for measurement: ask the stack for a post-quantum DTLS key exchange. Off everywhere else (owner
    /// decision 2026-10-12: known-good algorithms only).
    public var dtlsPqcTrial = false
    /// Test builds only: ``MediaFaults``.
    public var faults = MediaFaults()
    /// Test builds only (CALLS-PLAN §3.1, C5): gather and use relayed candidates alone, so the call goes through the vault's
    /// TURN server or not at all.
    public var relayOnly = false

    public init(dtlsPqcTrial: Bool = false, faults: MediaFaults = MediaFaults(), relayOnly: Bool = false) {
        self.dtlsPqcTrial = dtlsPqcTrial
        self.faults = faults
        self.relayOnly = relayOnly
    }

    /// No test option on: the only configuration a build members use may make.
    public var plain: Bool { !dtlsPqcTrial && !faults.any && !relayOnly }
}

/// The media of one call. One engine is one call: it is created for it and ``close()``d with it.
///
/// The rules an implementation keeps (CALL-MEDIA §7):
/// - frame encryption is in place and enabled on the sender and on the receiver before any SDP is applied, and is never
///   switched off;
/// - no media exists outside that encryption: after the other side's SDP has been applied there is exactly one media section,
///   the one that carries the cryptors, or ``MediaNotEncryptedError``; and the other side's SDP reaches the stack without
///   `a=ssrc` lines, so that the receiver's decryption covers every stream of the section;
/// - a sender without a key sends nothing; a frame that does not decrypt is never played;
/// - nothing of the stack's own logging is ever switched on;
/// - ``setKeys(_:send:receive:)`` takes the keys into the stack and wipes the arrays it was given.
@MainActor
public protocol MediaEngine: AnyObject {
    /// The suites this engine can encrypt with (``MediaSuite/preference`` order): what the device offers and accepts, cut down
    /// by the call's form (``CallSignalling/offerable(_:)``; form 1: suite 1 only, ``MediaSuite/formOne(_:)``).
    var suites: [MediaSuite] { get }

    /// One consumer (the call). Events from the moment the engine exists are kept for it.
    var events: AsyncStream<MediaEvent> { get }

    /// The caller's SDP offer, with the frame cryptors made for [suite]: the only suite the call can then use (the first, and
    /// under form 1 the only, suite it offers). Nothing is gathered and nothing is sent yet.
    func createOffer(suite: MediaSuite) async throws -> String

    /// The caller, once its vault has answered `call.start`: start gathering addresses, with [servers] and no others.
    func startGathering(servers: [CallWire.IceServer]) async throws

    /// The caller takes the answer. ``setKeys(_:send:receive:)`` comes first.
    func acceptAnswer(sdp: String) async throws

    /// The callee, when the member answers: takes the offer and returns the SDP answer, with the frame cryptors made for
    /// [suite], the one chosen when the offer was checked. Gathering starts.
    func acceptOffer(sdp: String, servers: [CallWire.IceServer], suite: MediaSuite) async throws -> String

    /// The call's two frame keys for [suite], which must be the suite the cryptors were made for (``createOffer(suite:)``,
    /// ``acceptOffer(sdp:servers:suite:)``): the cryptors are never remade, so keys for another suite are refused
    /// (``MediaNotEncryptedError``; the call ends). Both arrays are wiped before this returns, in place.
    func setKeys(_ suite: MediaSuite, send: inout [UInt8], receive: inout [UInt8]) async throws

    /// The other device's addresses. Only after its SDP has been applied.
    func addRemoteCandidates(_ candidates: [CallCandidate]) async throws

    func setMuted(_ muted: Bool)

    /// (C2, VAULT-MESSAGING "Key confirmation") Holds this device's outgoing track back whatever the member's mute says: the
    /// answering device sends no media until its receiver first decrypts a frame. The track sends only when it is neither
    /// muted nor held.
    func setHeld(_ held: Bool)

    /// A reading of the stack's statistics, or nil while there are none.
    func diagnostics() async -> MediaDiagnostics?

    /// Ends the media and frees everything. Safe to call twice.
    func close()
}

@MainActor
public protocol MediaEngineFactory: AnyObject {
    /// The suites every engine of this factory can encrypt with (``MediaSuite/preference`` order). Known without an engine: an
    /// incoming offer is checked against it before the phone rings, when no engine exists yet.
    var suites: [MediaSuite] { get }

    /// A new engine for one call. May load the media stack on its first use.
    func create(config: MediaConfig) throws -> any MediaEngine
}
