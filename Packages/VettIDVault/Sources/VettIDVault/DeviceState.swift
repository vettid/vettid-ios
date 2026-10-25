import Foundation

/// The device's persistent state (secret: it holds session keys). Stored only through a ``DeviceStateStore``, encrypted
/// at rest by the app (VettIDData). The device's own private keys are not in it: they come from the Secure Enclave and
/// the encrypted file store as ``DeviceSecrets``. Mutated only under the device's lock. Mirrors vettid-android
/// `DeviceState`.
final class DeviceState: Codable, @unchecked Sendable {
    var role: String
    var name: String
    var relayURL: String
    var vaultID: String?
    var deviceID: String?
    var vault: VaultRecord?
    /// Relay msg_ids seen (16 days, §8.2), with when (epoch ms).
    var seen: [String: Int64] = [:]
    /// Inner ids of the vault's messages seen (16 days, §8.2).
    var seenInner: [String: Int64] = [:]
    /// Expiry of the standing token last given to the vault (epoch ms).
    var issuedExpMs: Int64 = 0
    /// The alternate-channel state (``AltState`` JSON).
    var alt: String?
    var credential: CredentialCopy?
    var utks: [UtkRecord] = []
    var recovery: RecoveryRecord?
    var outbox: [OutboxEntry] = []
    /// The vault has shown this app a signer on its own `device.list` entry (VAULT-MESSAGING 0.27.0 §11.7.1).
    var signerSeen = false
    /// (VAULT-MESSAGING 0.46.0 §11.14.9 step 1) This device's credential requests that may still reach the vault: inner
    /// id to `exp` (epoch ms), until answered or the vault's clock is past `exp` by more than a minute. Optional: a state
    /// written before it existed has none.
    var unsettled: [String: Int64]?
    /// The member's `user_guid` from a transfer's `device.paired` (0.17.0, §6.7.1), kept until the move is completed: a start
    /// after the app was killed between `device.paired` and the take-over still has it. Optional: older states have none.
    var transferUserGuid: String?

    init(role: String, name: String, relayURL: String) {
        self.role = role
        self.name = name
        self.relayURL = relayURL
    }
}

/// What the device knows about its vault. Keys are standard base64.
struct VaultRecord: Codable, Sendable {
    var ik: String
    var kem: String
    var relayURL: String
    var mailbox: String
    var relayPk: String
    var token = ""
    var tokenExpMs: Int64 = 0
    /// The keyring's export (base64).
    var sessions = ""
    var suite = 0
    /// The vault's rekeys this device answered with `hs.resp` whose `hs.fin` has not arrived (§6.5): kept across a
    /// restart, so that the `hs.fin` still finds its handshake. Secret, like [sessions].
    var awaiting: [AwaitingRekey] = []
}

/// A responder awaiting `hs.fin` (its export, base64) and when it began.
struct AwaitingRekey: Codable, Sendable {
    let createdMs: Int64
    let state: String
}

/// This app's copy of the Protean Credential (§3.5): the sealed blob, useless without the vault's CEK and the password.
struct CredentialCopy: Codable, Sendable {
    let blob: String
    let version: Int64
}

/// An issued one-time transaction key (§3.5.4).
struct UtkRecord: Codable, Sendable, Equatable {
    let id: String
    let ek: String
    let expiresAtMs: Int64
}

/// Set while this app recovers a vault (§11.11).
struct RecoveryRecord: Codable, Sendable {
    let recoveryID: String
    var requestID = ""
    var credentialBackup: Bool?
    /// (IOS-PLAN 0.1.33 §4.9) The `request_id` of every `vault.recovery.open` this identity built, kept before the request is
    /// posted: a phone that could not tell whether an open recovered the vault reads the slot of the earlier one once.
    /// Optional: a state written before it existed has none.
    var opens: [RecoveryOpenEntry]?
}

/// What is known of one open this identity built (IOS-PLAN 0.1.34 §4.10): kept per open, never as the last answer. An entry is
/// written, unanswered, in the same save that stores its `request_id`, before the open is posted.
public struct RecoveryOpenEntry: Codable, Sendable, Equatable {
    public enum State: Codable, Sendable, Equatable {
        /// Posted (or about to be) with no answer that proves no step 1 was stored.
        case unanswered
        /// Proven not to have stored step 1: a definite non-acceptance, or an answer that proves it (the code).
        case refused(String)
        /// The vault answered `ok`.
        case ok
    }

    public let id: String
    public var state: State
    /// The code of the vault's sealed answer to this open when one was read (whatever it proved for §4.10): an open whose answer is
    /// sealed and is not `ok` or `retry` stored no invitation under this identity's `recovery_id` (the vault writes it only after
    /// the wrap opens, vettid-vault `recovery_open.go`). Nil: no answer was read.
    public var answer: String?
}

/// A deposit not yet answered 201 by the relay (§8.3: the entry goes once the relay accepted it).
struct OutboxEntry: Codable, Sendable, Equatable {
    let id: String
    let type: String
    let relayURL: String
    let mailbox: String
    let token: String
    let envelope: String
    var attempts = 0
}

/// Where the device state is kept. [save] must be durable before it returns (ack after persist, §8.3).
public protocol DeviceStateStore: Sendable {
    func load() throws -> [UInt8]?
    func save(_ state: [UInt8]) throws
    func clear() throws
}

/// In memory only (tests).
public final class InMemoryDeviceStateStore: DeviceStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var b: [UInt8]?

    public init() {}

    public func load() -> [UInt8]? { lock.withLock { b } }
    public func save(_ state: [UInt8]) { lock.withLock { b = state } }
    public func clear() { lock.withLock { b = nil } }
}
