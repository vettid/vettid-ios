import Foundation
import VettIDCrypto

// Body models of VAULT-MESSAGING §10.2 and §10.3. Unknown members are ignored (§10.1); a member a vault of an earlier
// version does not send is nil. Decoded with `VaultJSON.decode` (snake_case keys). Later phases add the models of the
// other §10 sections as they add their calls. Mirrors vettid-android `Models.kt`.

/// `vault.status` (§10.2).
public struct VaultStatusInfo: Decodable, Equatable, Sendable {
    public let vaultId: String
    public let stateSeq: Int64?
    public let headerSeq: Int64?
    public let provisional: Bool?
    public let devices: Int?
    public let connections: Int?
    /// The daily owner check (§3.6, 0.13.0).
    public let ownerCheck: OwnerCheckStatus?
    /// (0.29.0, release L) The current unlock's id, to the app and desktops.
    public let unlockId: String?
    /// (0.33.0, release R) Recovery's state and attempts (§11.14.11).
    public let recovery: RecoveryStatus?
}

/// `vault.status`'s `owner_check` (§3.6, §3.6.7): `state` is `ok`, `due` or `held`.
public struct OwnerCheckStatus: Decodable, Equatable, Sendable {
    public let state: String
    public let deadline: String?
    public let intervalSeconds: Int64?
    public let failures: Int?
    public let hold: Bool?
    public let holdOffUntil: String?
    /// (0.19.0, while `due` or `held`) what arrived since the deadline, as `vault.held` counts it.
    public let waiting: HeldCounts?
    /// (0.29.0, release L) When the vault locks itself if no check is passed (§3.6.8).
    public let idleLockAt: String?
}

/// `vault.owner-check`'s answer (§3.6.1), less the blob and UTKs the credential layer keeps.
public struct OwnerCheckPassed: Decodable, Equatable, Sendable {
    public let deadline: String?
    public let intervalSeconds: Int64?
    public let hold: Bool?
    public let holdOffUntil: String?
    /// (0.33.0, release R) `recovery{state, present_recorded}` (§11.14.5): `present_recorded` false means the vault could
    /// not record that the member was here (the presence notice).
    public let recovery: OwnerCheckRecovery?
}

/// The owner check answer's `recovery` (VAULT-MESSAGING 0.33.0 §11.14.5).
public struct OwnerCheckRecovery: Decodable, Equatable, Sendable {
    public let state: String?
    public let presentRecorded: Bool?
}

/// `vault.held` (§3.6.3): content-free counts of what waits since the deadline.
public struct HeldNotice: Decodable, Equatable, Sendable {
    public let deadline: String?
    public let waiting: HeldCounts?
    public let idleLockAt: String?
}

/// `vault.held`'s `waiting`.
public struct HeldCounts: Decodable, Equatable, Sendable {
    public let messages: Int?
    public let requests: Int?
    public let calls: Int?
    public let other: Int?
}

/// `vault.status`'s `recovery` (0.33.0, release R, §11.14.11).
public struct RecoveryStatus: Decodable, Equatable, Sendable {
    public let state: String?
    public let attempts: RecoveryAttempts?
    public let presentRecordedAt: String?
    public let counter: String?
}

public struct RecoveryAttempts: Decodable, Equatable, Sendable {
    public let used: Int?
    public let of: Int?
}

/// `account.get` (§10.2, 0.15.0): `account` nil (and `version` 0) before any snapshot arrived. A change of
/// `name_request` alone repeats the stored `version` in `sync.event{account.changed}` (0.19.0): never skip one.
public struct AccountView: Decodable, Equatable, Sendable {
    public let account: AccountSnapshot?
    public let version: Int64?
    public let receivedAt: String?
    /// The latest `account.name.set` request (0.18.0, §10.8).
    public let nameRequest: NameRequest?
}

/// The member API's account snapshot as the vault keeps it (§11.13), display only. Encodable as well: the account record
/// keeps the last one.
public struct AccountSnapshot: Codable, Equatable, Sendable {
    public let v: Int?
    public let asOf: String?
    public let emailHint: String?
    /// The full address (0.20.0).
    public let email: String?
    public let state: String?
    /// `active` or `canceled`.
    public let accountStatus: String?
    public let deletesAt: String?
    public let terms: AccountTerms?
    public let subscription: AccountSubscription?
    public let votingRights: Bool?
    /// The account's names (0.18.0): what every connection sees in the shared profile's core (§10.8).
    public let firstName: String?
    public let lastName: String?
    /// (0.18.0) When the next name change may be applied (§10.8).
    public let nameChange: AccountNameChange?
}

/// The snapshot's `name_change` (§11.13): `allowed_after`, null when a change may be applied now.
public struct AccountNameChange: Codable, Equatable, Sendable {
    public let allowedAfter: String?
}

public struct AccountTerms: Codable, Equatable, Sendable {
    public let needsAcceptance: Bool?
}

public struct AccountSubscription: Codable, Equatable, Sendable {
    public let typeName: String?
    /// `trial`, `active`, `expired` or `canceled`.
    public let status: String?
    public let paid: Bool?
    public let expiresAt: String?
}

/// An `account.name.set` request (0.18.0, §10.8). Encodable as well: the account record keeps the latest one.
public struct NameRequest: Codable, Equatable, Sendable {
    public let seq: Int64
    public let firstName: String
    public let lastName: String
    public let requestedAt: String?
    public let state: String
    public let reason: String?

    public init(seq: Int64, firstName: String, lastName: String, requestedAt: String?, state: String, reason: String? = nil) {
        self.seq = seq
        self.firstName = firstName
        self.lastName = lastName
        self.requestedAt = requestedAt
        self.state = state
        self.reason = reason
    }
}

/// `credential.version` (§10.6): whether the vault holds a credential, its version, key and last change, and an open
/// clone alarm (§3.5.9).
public struct CredentialInfo: Decodable, Equatable, Sendable {
    public let exists: Bool
    public let version: Int64?
    public let key: String?
    public let updatedAt: String?
    public let alarm: CredentialAlarmInfo?
}

/// `credential.version`'s `alarm` (§3.5.9).
public struct CredentialAlarmInfo: Decodable, Equatable, Sendable {
    public let alarmID: String?
    public let state: String?
    public let at: String?

    enum CodingKeys: String, CodingKey {
        case alarmID = "alarmId"
        case state, at
    }
}

/// One page of `item.list` (§10.7) as the credential screen counts it: how many items the page holds and the cursor of
/// the next page. The items themselves come with the Vault screens (IOS-PLAN §8 I3.1).
public struct ItemCountPage: Equatable, Sendable {
    public let count: Int
    public let next: String?
}

/// `device.pair.create`'s answer (§10.3): the link a desktop or an agent scans.
public struct PairingOffer: Equatable, Sendable {
    public let pairingID: String
    public let link: String
    public let exp: String?
}

/// `device.transfer.create`'s answer (§10.3): [link] is the pairing link the new phone scans.
public struct TransferOffer: Equatable, Sendable {
    public let transferID: String
    public let link: String
    public let exp: String?
}

/// `device.transfer.pending` (§10.3): the new app's self-asserted [name] and the SAS to compare. (0.27.0, §11.7.1)
/// [signer]: the attested class of the new app's signer; [signerChanged]: it differs from the vault's binding.
public struct TransferPending: Equatable, Sendable {
    public let transferID: String
    public let name: String
    public let sas: String
    public let signer: String?
    public let signerChanged: Bool

    /// The body of a `device.transfer.pending` for [transferID]; `signer_changed` counts only as a JSON `true`.
    static func of(_ transferID: String, _ o: JsonObject) -> TransferPending {
        TransferPending(
            transferID: transferID, name: VaultJSON.string(o, "name") ?? "", sas: VaultJSON.string(o, "sas") ?? "",
            signer: VaultJSON.string(o, "signer"), signerChanged: VaultJSON.bool(o, "signer_changed") == true
        )
    }
}

/// A device of the vault (`device.list`, §10.3). `name` and `profile` are self-asserted.
public struct DeviceEntry: Decodable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let state: String
    public let name: String?
    public let ik: String?
    public let createdAt: String?
    public let lastActiveAt: String?
    public let sessionExpiresAt: String?
    /// (0.27.0) Only on an Android app's entry with a recorded signer (§11.7.1).
    public let signer: DeviceSigner?
}

public struct DeviceSigner: Decodable, Equatable, Sendable {
    public let `class`: String
    public let digest: String
}

/// `sync.event` (§10.1): a side effect of the owner's other devices.
public struct SyncEvent: Sendable {
    public let kind: String
    public let body: [UInt8]
}
