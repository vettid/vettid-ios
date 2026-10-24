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
