import Foundation
import VettIDCrypto

/// One function per VAULT-MESSAGING §10.2, §10.3 and §10.4 type the app sends (§10.4 in `VaultApi+Connections.swift`),
/// plus the events it receives (§10.1 `sync.event`, §10.2 `vault.held`), and the credential calls of enrollment (§10.6,
/// ``credentialCreate(password:pin:)``). Errors are ``VaultOpError`` with the spec's code. The other §10 sections
/// (messaging, items, the other credential operations, …) come with the phases that use them. Mirrors vettid-android
/// `VaultApi`.
public struct VaultApi: Sendable {
    /// How long the app waits for the vault's answer to `vault.lock`.
    public static let lockAnswer: TimeInterval = 10
    /// How long after it was asked a `vault.lock` may still be acted on.
    public static let lockValid: TimeInterval = 30
    /// The approvals the app shows (ANDROID-PLAN §4 Approvals).
    public static let approvalTypes: Set<String> = [
        "connection.request.pending", "connection.request.outgoing", "grant.pending", "critical-secret-use.pending",
        "share.pending", "approval.pending", "device.session.pending", "connection.authenticate.pending", "credential.alarm",
    ]

    public let device: VaultDevice
    /// (VAULT-MESSAGING §11.14.7) Whether the vault is of release R, asked at each credential operation: its passwords
    /// are normalized to NFC before they are sealed. False sends every password exactly as typed, as before release R.
    let normalizePasswords: @Sendable () -> Bool

    /// Checked under the credential lock before every credential operation with the blob, and again before its
    /// `stale_credential` retry, with whether its payload carries the PIN: it throws to refuse the operation
    /// (VAULT-MESSAGING §11.14.9 "A lost answer": nothing credential-bearing while a change of PIN or password is on its
    /// way or unresolved, nothing with the PIN while the PIN is uncertain).
    let credentialGate: @Sendable (_ carriesPin: Bool) async throws -> Void

    /// How a change of PIN or password waits for the credential operations before it (VAULT-MESSAGING §11.14.9 step 1:
    /// at most 30 s, then refused): a sleep of the given length; a test passes its own.
    let changeWaitSleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        device: VaultDevice, normalizePasswords: @escaping @Sendable () -> Bool = { false },
        credentialGate: @escaping @Sendable (_ carriesPin: Bool) async throws -> Void = { _ in },
        changeWaitSleep: @escaping @Sendable (TimeInterval) async throws -> Void = VaultApi.sleep
    ) {
        self.device = device
        self.normalizePasswords = normalizePasswords
        self.credentialGate = credentialGate
        self.changeWaitSleep = changeWaitSleep
    }

    /// A sleep of [seconds] (cancellable). A closure, not a static method: with Swift 6.2 (Xcode 26), a reference to the
    /// method as a function value, cancelled while it sleeps in ``AsyncLock``'s give-up timer, aborted the process
    /// ("freed pointer was not the last allocation" in `swift_task_dealloc`).
    public static let sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1e9))
    }

    var credential: CredentialOps {
        CredentialOps(device: device, normalizePasswords: normalizePasswords, gate: credentialGate, changeWaitSleep: changeWaitSleep)
    }

    private func op(_ type: String, _ body: JsonBuilder? = nil) async throws -> [UInt8] {
        try await device.op(type, body: body?.bytes() ?? VaultJSON.empty)
    }

    // MARK: - Events (§9.1, §10.1)

    /// Events of [type], as they arrive.
    public func events(_ type: String) -> AsyncFilterSequence<AsyncStream<VaultMessage>> {
        device.events().filter { $0.type == type }
    }

    /// `sync.event`: side effects of the owner's other devices (§10.1).
    public func syncEvents() -> AsyncMapSequence<AsyncFilterSequence<AsyncStream<VaultMessage>>, SyncEvent> {
        events("sync.event").map { SyncEvent(kind: VaultJSON.string($0.object, "kind") ?? "", body: $0.body) }
    }

    /// The approvals the app shows: connection requests, grants, critical-item uses, share decisions, held requests.
    public func approvals() -> AsyncFilterSequence<AsyncStream<VaultMessage>> {
        device.events().filter { Self.approvalTypes.contains($0.type) }
    }

    /// Waits for the next event of [type] whose body matches.
    public func awaitEvent(
        _ type: String, timeout: TimeInterval = VaultDevice.awaitDefault, match: @escaping @Sendable (VaultMessage) -> Bool = { _ in true }
    ) async throws -> VaultMessage {
        try await device.awaitEvent(type, timeout: timeout, match: match)
    }

    // MARK: - Lifecycle (§10.2)

    public func enrollConfirm() async throws { _ = try await op("vault.enroll.confirm") }

    public func status() async throws -> VaultStatusInfo { try VaultJSON.decode(VaultStatusInfo.self, try await op("vault.status")) }

    /// `account.get` (§10.2, §11.13, 0.15.0): the member's account snapshot from the member API, display only.
    public func accountGet() async throws -> AccountView { try VaultJSON.decode(AccountView.self, try await op("account.get")) }

    /// Locks the vault (it answers, then sends vault.locking). Deposited **once** and with an `exp`: never from the
    /// outbox, so a lock that could not be delivered is not delivered by a later flush, and the vault drops one that
    /// reaches it more than [validFor] after it was asked. (0.29.0, release L) [unlockID] binds the lock to the unlock
    /// it ends (`stale_lock` when the vault is open under a newer one). Throws without an answer within [timeout].
    public func lock(unlockID: String? = nil, timeout: TimeInterval = lockAnswer, validFor: TimeInterval = lockValid) async throws {
        let body = JsonBuilder()
        if let u = unlockID { body.string("unlock_id", u) }
        _ = try await device.opOnce("vault.lock", body: body.bytes(), timeout: timeout, exp: device.now().addingTimeInterval(validFor))
    }

    // MARK: - Devices (§10.3)

    public func deviceList() async throws -> [DeviceEntry] {
        struct List: Decodable { let devices: [DeviceEntry] }
        return try VaultJSON.decode(List.self, try await op("device.list")).devices
    }

    /// `device.unlink`; `forbidden` for the app itself (it leaves by a transfer or a recovery).
    public func deviceUnlink(_ deviceID: String) async throws {
        _ = try await op("device.unlink", JsonBuilder().string("device_id", deviceID))
    }

    /// `device.pair.create` for a desktop or an agent: the pairing link.
    public func pairCreate(role: String) async throws -> PairingOffer {
        let o = VaultJSON.object(try await op("device.pair.create", JsonBuilder().string("role", role)))
        guard let id = VaultJSON.string(o, "pairing_id"), let link = VaultJSON.string(o, "link") else {
            throw VaultStateError(message: "pairing without id or link")
        }
        return PairingOffer(pairingID: id, link: link, exp: VaultJSON.string(o, "exp"))
    }

    public func pairApprove(_ pairingID: String, sessionSeconds: Int? = nil) async throws {
        let b = JsonBuilder().string("pairing_id", pairingID)
        if let s = sessionSeconds { b.uint("session_seconds", UInt64(s)) }
        _ = try await op("device.pair.approve", b)
    }

    public func pairReject(_ pairingID: String) async throws {
        _ = try await op("device.pair.reject", JsonBuilder().string("pairing_id", pairingID))
    }

    public func sessionApprove(_ requestID: String, seconds: Int? = nil) async throws -> [UInt8] {
        let b = JsonBuilder().string("request_id", requestID)
        if let s = seconds { b.uint("seconds", UInt64(s)) }
        return try await op("device.session.approve", b)
    }

    public func sessionDeny(_ requestID: String) async throws {
        _ = try await op("device.session.deny", JsonBuilder().string("request_id", requestID))
    }

    /// Ends a desktop's or an agent's access session.
    public func sessionEnd(deviceID: String) async throws {
        _ = try await op("device.session.end", JsonBuilder().string("device_id", deviceID))
    }

    /// Decides a desktop's step-up request or an agent's referred request (`approval.pending`); returns its outcome.
    public func approvalDecide(_ approvalID: String, approve: Bool) async throws -> String? {
        let o = VaultJSON.object(try await op("approval.decide", JsonBuilder().string("approval_id", approvalID).bool("approve", approve)))
        return VaultJSON.string(o, "result")
    }

    // MARK: - Direct transfer, the old app's side (§6.7.1, §10.3)

    /// `device.transfer.create`: the QR link (pairing kind `p`, TTL 10 minutes) for the new phone.
    public func transferCreate() async throws -> TransferOffer {
        let o = VaultJSON.object(try await op("device.transfer.create"))
        guard let id = VaultJSON.string(o, "transfer_id") else { throw VaultStateError(message: "transfer without id") }
        guard let link = VaultJSON.string(o, "link") else { throw VaultStateError(message: "transfer without link") }
        return TransferOffer(transferID: id, link: link, exp: VaultJSON.string(o, "exp"))
    }

    /// Waits for `device.transfer.pending{transfer_id, name, sas, signer?, signer_changed?}`: the new app's handshake
    /// checked out.
    public func awaitTransferPending(_ transferID: String, timeout: TimeInterval) async throws -> TransferPending {
        let m = try await device.awaitEvent("device.transfer.pending", timeout: timeout) {
            VaultJSON.string($0.object, "transfer_id") == transferID
        }
        return TransferPending.of(transferID, m.object)
    }

    /// `device.transfer.reject`: cancels the transfer before or after the scan.
    public func transferReject(_ transferID: String) async throws {
        _ = try await op("device.transfer.reject", JsonBuilder().string("transfer_id", transferID))
    }
}
