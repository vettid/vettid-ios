#if DEBUG
import Foundation
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The state of the fake's direct transfer (VAULT-MESSAGING §6.7.1, §11.14.10), under the service's lock.
struct FakeTransferStore {
    // The vault as a transfer's target (the new phone's side).
    var inviteID: String?
    var claimID: String?
    var claimBlob: [UInt8]?
    var pin = ""
    var password = ""
    var holdApproval = false
    var ignoresInit = false
    var withoutUserGuid = false
    var unlockSecret: [UInt8]?
    var inits: [FakeVaultService.TransferInitSeen] = []
    var paired = false
    // The vault as the old phone's (the approving side).
    var open: String?
    var offers = 0
    var rejected: [String] = []
    var approvals: [FakeVaultService.TransferApprovalSeen] = []
    var signerRequired: String?
    var earlierRelease = false
    var approved = false
    var tookEffect = true
    var listRequests = 0
    var listAnswer: FakeVaultService.DeviceListAnswer?
    var revokesDeposits = false
    /// The vault's relay refuses the deposit that follows its `hs.resp` (the new phone's `hs.fin`) as revoked.
    var revokesFin = false
    /// The vault takes the new phone's `hs.fin` but its answer is lost in transport (and again for every later deposit).
    var losesFinAnswers = false
    var finSeen = false
    /// The lifetime of the request token the vault's `hs.resp` carries (a pairing's is 10 minutes, §6.7); nil: a standing one.
    var requestTokenTTL: TimeInterval?
    var revokedDeposits = 0
    var collectRefused = false
    var collectFailures = 0
    var collectRefusals = 0
    /// The collects of the device's mailbox being answered now (a long poll held while nothing waits), by number. (Kept
    /// here for the file's length; they count every collect of the device's mailbox.)
    var collecting: Set<Int> = []
    var collectSeq = 0
    /// At the last restart of a test phone: the collects its old process left in flight, and whether one outlived the wait.
    var restartLeft = 0
    var restartOutlived = false
    /// RELAY-PROTOCOL §6.3's lease, when a test asks for it: a collected message not acked within it is collected again.
    var leaseFor: TimeInterval?
    var claimGate: FakeHTTPServer.Gate?
    var collectGate: FakeHTTPServer.Gate?
    var opensAtDelete = false
    var collectGateWait: Int?
    var collectAnswersLost = 0
    var visibility = 60
    var registerRefused = false
    var leased: [(message: RelayMessage, until: Date)] = []
}

// TEST ONLY. A direct transfer in both directions, as vettid-vault answers it: as the new phone's target
// (``armTransferTarget(pin:password:)``: the claim, the attested `hs.init`, `device.paired{transfer}`, then the credential
// calls of the take-over) and as the old phone's vault (`device.transfer.create`, `.reject` and `.approve`, and the
// `device.list` of the end-of-keep check).
extension FakeVaultService {
    /// What the vault received in a transfer's `hs.init`.
    public struct TransferInitSeen: Sendable {
        public let ctx: String
        public let platform: String?
        public let keyID: [UInt8]?
        public let apiKey: [UInt8]?
        public let unlockSecret: [UInt8]?
    }

    /// What the vault received in one `device.transfer.approve`.
    public struct TransferApprovalSeen: Sendable, Equatable {
        public let transferID: String
        public let pin: String
        public let password: String
        public let signer: String?
    }

    // MARK: - The new phone's side

    /// The transfer's `hs.init`s the vault received, in order.
    public var transferInits: [TransferInitSeen] { locked { transfer.inits } }

    /// Whether `device.paired{transfer}` was sent.
    public var transferPaired: Bool { locked { transfer.paired } }

    /// The vault the transfer moves: it holds a credential under [pin] and [password], and a QR for a new phone to scan is
    /// returned (the sealed bundle waits as a claim on the vault's relay, fetched once). Capabilities and time scale are
    /// the instance's.
    public func armTransferTarget(pin: String, password: String, validFor: TimeInterval = 600) throws -> String {
        try locked {
            let inviteID = Ulid.new()
            let exp = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + validFor).rounded(.down))
            let vaultPrincipal = Principal(ik: ik.publicKey, kem: kem.publicKey, relay: RelayAddr(url: vaultRelay.baseURL, mailbox: vaultMailbox, pk: relayKey.publicKey))
            let bundle = InviteBundle(
                kind: .app, inviteID: inviteID, remote: false, vault: vaultPrincipal,
                token: try token(RelayAddr(url: relay.baseURL, mailbox: "x", pk: Ed25519PrivateKey.generate().publicKey)), exp: exp,
                capabilities: capabilitiesValue ?? [], timeScale: timeScaleValue
            )
            let sealed = try InviteBundle.seal(try bundle.marshal())
            let claimID = Self.claimID()
            transfer.inviteID = inviteID
            transfer.claimID = claimID
            transfer.claimBlob = sealed.blob
            transfer.pin = pin
            transfer.password = password
            hasCredential = true
            vaultMade = true
            vaultPin = pin
            vaultPassword = password
            credentialVersion = 4
            let qr = InviteQr(kind: .app, relay: vaultRelay.baseURL, claimID: claimID, hash: sealed.hash, key: sealed.key, exp: UInt64(exp.timeIntervalSince1970))
            return String(bytes: try qr.marshal(), encoding: .utf8) ?? ""
        }
    }

    /// The old phone does not approve at once: `device.paired` waits for ``approveTransferIn()`` (or the rejection).
    public var holdsTransferApproval: Bool {
        get { locked { transfer.holdApproval } }
        set { locked { transfer.holdApproval = newValue } }
    }

    /// The lifetime of the request token that the vault's `hs.resp` carries to the new phone.
    public var transferRequestTokenTTL: TimeInterval? {
        get { locked { transfer.requestTokenTTL } }
        set { locked { transfer.requestTokenTTL = newValue } }
    }

    /// The vault takes the new phone's `hs.fin` and the relay's answer is lost: the fin stays owed on the phone.
    public var transferLosesFinAnswers: Bool {
        get { locked { transfer.losesFinAnswers } }
        set { locked { transfer.losesFinAnswers = newValue } }
    }

    /// The vault's relay refuses the new phone's `hs.fin` for good (`token_revoked`) while the `hs.init` was taken.
    public var transferRevokesFin: Bool {
        get { locked { transfer.revokesFin } }
        set { locked { transfer.revokesFin = newValue } }
    }

    /// The vault drops the new phone's `hs.init` unanswered (a spent link, a failed attestation, §6.7.1 step 2).
    public var transferIgnoresInit: Bool {
        get { locked { transfer.ignoresInit } }
        set { locked { transfer.ignoresInit = newValue } }
    }

    /// A vault release before 0.17.0: `device.paired` carries no `user_guid`.
    public var transferWithoutUserGuid: Bool {
        get { locked { transfer.withoutUserGuid } }
        set { locked { transfer.withoutUserGuid = newValue } }
    }

    /// The old phone approved: the vault completes the transfer and sends the new phone `device.paired{transfer}`.
    public func approveTransferIn() { locked { try? completeTransferIn() } }

    /// The old phone rejected after the new phone's `hs.fin`: `device.pair.rejected`.
    public func rejectTransferIn() { locked { try? reply("device.pair.rejected", "{}") } }

    /// The claim of the transfer's QR, fetched once (``answerVaultRelay(_:)``). Callers hold ``cond``.
    func transferClaim(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        guard r.path == "/v1/claim/\(transfer.claimID ?? "-")", let blob = transfer.claimBlob else {
            return .json(404, #"{"code":"claim_unknown","message":""}"#)
        }
        transfer.claimBlob = nil
        if let gate = transfer.claimGate { return .held(gate, .bytes(200, blob)) }
        return .bytes(200, blob)
    }

    /// The new phone's `hs.init` of the armed transfer: answered with `hs.resp` at once (§6.7.1 step 2). Callers hold ``cond``.
    func acceptTransferInit(_ raw: [UInt8]) throws {
        let kem = kem
        let p = try PendingInit.open(raw, lookup: { k in k == kem.publicKey.kid ? kem : nil }, now: Date())
        let attest = p.body.deviceAttest
        transfer.inits.append(TransferInitSeen(ctx: p.body.ctx, platform: attest?.platform, keyID: attest?.iosKeyID, apiKey: p.body.apiKey, unlockSecret: p.body.unlockSecret))
        // A dropped hs.init (a spent link, a wrong invitation) is never answered.
        guard p.body.ctx == transfer.inviteID, attest != nil, p.body.purpose == .app, !transfer.ignoresInit else { return }
        transfer.unlockSecret = p.body.unlockSecret
        deviceIk = p.body.from.ik
        device = (kem: p.body.from.kem, relay: p.body.from.relay)
        let (resp, env) = try p.respond(ResponderConfig(identity: ik, token: try token(p.body.from.relay, ttl: transfer.requestTokenTTL ?? DepositTokens.standingTTL), policy: .vaultToDevice, collectSender: p.body.from.relay.pk))
        responder = resp
        queue(env)
    }

    /// The new phone's `hs.fin`: with the approval at hand the transfer completes, else it waits. Callers hold ``cond``.
    func transferFinished() throws {
        if !transfer.holdApproval { try completeTransferIn() }
    }

    /// The approval completed the transfer: the vault now holds the new phone's secret, and sends `device.paired`. Callers
    /// hold ``cond``.
    func completeTransferIn() throws {
        guard transfer.inviteID != nil, !transfer.paired else { return }
        transfer.paired = true
        vaultSecret = transfer.unlockSecret
        let guid = transfer.withoutUserGuid ? "" : #","user_guid":"\#(userGuid)""#
        try reply("device.paired", #"{"device_id":"dev-2","role":"app","vault_id":"\#(vaultID)","release":"\#(Self.pcr0)","release_number":3,"transfer":true\#(guid),"credential_version":\#(credentialVersion)}"#)
    }

    // MARK: - The old phone's side

    /// The transfers this vault was asked to cancel.
    public var transfersRejected: [String] { locked { transfer.rejected } }

    /// The approvals the vault received, in order.
    public var transferApprovals: [TransferApprovalSeen] { locked { transfer.approvals } }

    /// The `device.transfer.create`s answered.
    public var transferOffers: Int { locked { transfer.offers } }

    /// The class the vault wants confirmed (``device.transfer.pending``'s `signer_changed`, §11.7.1): an approval that does
    /// not name it is answered `signer_unconfirmed` before anything is checked or counted (the UTK spent, 0.52.0).
    public var transferSignerRequired: String? {
        get { locked { transfer.signerRequired } }
        set { locked { transfer.signerRequired = newValue } }
    }

    /// A vault release before R: the approval is answered `{}` (the transfer is complete, no keys are kept).
    public var transferEarlierRelease: Bool {
        get { locked { transfer.earlierRelease } }
        set { locked { transfer.earlierRelease = newValue } }
    }

    /// Whether an approval took effect at the vault (the default): then it has removed this phone and answers its
    /// `device.list` no more. False: the write was not stored, this phone is still the vault's app (§11.14.10).
    public var transferTookEffect: Bool {
        get { locked { transfer.tookEffect } }
        set { locked { transfer.tookEffect = newValue } }
    }

    /// How the vault answers `device.list` besides its transfer rules (nil: by them).
    public enum DeviceListAnswer: Sendable {
        /// An answer whose list does not name this phone.
        case withoutThisPhone
        /// An answer that names this phone as a `desktop`, not as the vault's app.
        case thisPhoneAsDesktop
        /// A refusal with this code.
        case refused(String)
    }

    public var deviceListAnswer: DeviceListAnswer? {
        get { locked { transfer.listAnswer } }
        set { locked { transfer.listAnswer = newValue } }
    }

    /// The relay refuses every deposit to the vault's mailbox with `token_revoked` (§7.4: a removed old phone's, RELAY-PROTOCOL
    /// §5.3 step 6): its `device.list` and its messages never reach the vault.
    public var revokesVaultDeposits: Bool {
        get { locked { transfer.revokesDeposits } }
        set { locked { transfer.revokesDeposits = newValue } }
    }

    /// How many deposits the relay refused for it.
    public var revokedDeposits: Int { locked { transfer.revokedDeposits } }

    /// This phone's own relay refuses its collects (the relay cannot be reached, or the mailbox is gone).
    public var refusesCollect: Bool {
        get { locked { transfer.collectRefused } }
        set { locked { transfer.collectRefused = newValue } }
    }

    /// The next [n] collects of this phone's own relay fail with a 503, which the collection tries again: then the relay
    /// connection comes back.
    public func failNextCollects(_ n: Int) { locked { transfer.collectFailures = n } }

    /// The next [n] collects of the device's mailbox are refused `429 rate_limited`, with `Retry-After: 7`.
    public func refuseNextCollects(_ n: Int) { locked { transfer.collectRefusals = n } }

    /// The collects of the device's mailbox the fake is answering now, by number: a long poll it holds while nothing
    /// waits, which takes the next message queued.
    public var collectsInFlight: Set<Int> { locked { transfer.collecting } }

    /// At the last restart of a test phone (``TestVaultPhone/restart()``): how many collects its old process left in
    /// flight at the halt, and whether one was still in flight when the wait for them gave up.
    public var lastRestartCollects: (left: Int, outlived: Bool) { locked { (transfer.restartLeft, transfer.restartOutlived) } }

    func noteRestart(left: Int, outlived: Bool) { locked { (transfer.restartLeft, transfer.restartOutlived) = (left, outlived) } }

    /// The messages queued for the device's mailbox, and those leased to a collect and not acked.
    public var mailboxCounts: (queued: Int, leased: Int) { locked { (queued.count, transfer.leased.count) } }

    /// While set, the claim of the transfer's QR is answered only when the gate opens (the scan held at its fetch).
    public var holdsClaim: FakeHTTPServer.Gate? {
        get { locked { transfer.claimGate } }
        set { locked { transfer.claimGate = newValue } }
    }

    /// While set, a collect that takes messages answers only when the gate opens: a long poll held out at the relay with
    /// what it was handed.
    public var holdsCollectAnswers: FakeHTTPServer.Gate? {
        get { locked { transfer.collectGate } }
        set { locked { transfer.collectGate = newValue } }
    }

    /// The `visibility_timeout_seconds` the device's relay registers with (60).
    public var relayVisibility: Int {
        get { locked { transfer.visibility } }
        set { locked { transfer.visibility = newValue } }
    }

    /// The device's relay refuses a registration (503): the limits cannot be read.
    public var refusesRegistration: Bool {
        get { locked { transfer.registerRefused } }
        set { locked { transfer.registerRefused = newValue } }
    }

    /// Only the collects of this `wait` are held (``holdsCollectAnswers``), and only they take messages meanwhile (the others
    /// find none): the test phone's collector long-polls with `wait=1`, a settlement window's collects with 0 or more.
    public var holdsCollectAnswersOfWait: Int? {
        get { locked { transfer.collectGateWait } }
        set { locked { transfer.collectGateWait = newValue } }
    }

    /// The long polls held out (``holdsCollectAnswers``) answer when the mailbox is deleted (a wipe), before its answer.
    public var opensHeldCollectsAtMailboxDelete: Bool {
        get { locked { transfer.opensAtDelete } }
        set { locked { transfer.opensAtDelete = newValue } }
    }

    /// How many of the next collects that take messages lose their answer in transport, the messages leased all the same
    /// (``leasesCollected``), as when the network drops a long poll's answer (with ``holdsCollectAnswers``, once the gate
    /// opens).
    public var losesCollectAnswers: Int {
        get { locked { transfer.collectAnswersLost } }
        set { locked { transfer.collectAnswersLost = newValue } }
    }

    /// The collect failures asked for (``failNextCollects(_:)``) not yet used.
    public var collectFailuresLeft: Int { locked { transfer.collectFailures } }

    /// The relay's lease of a collected message (RELAY-PROTOCOL §6.3: a message not acked within it reappears); nil, the
    /// default: a collected message is gone, acked or not.
    public var leasesCollected: TimeInterval? {
        get { locked { transfer.leaseFor } }
        set { locked { transfer.leaseFor = newValue } }
    }

    /// Every lease runs out now: the messages leased are collected again (the time of their lease passed).
    public func endLeases() { locked { transfer.leased = transfer.leased.map { ($0.message, Date.distantPast) } } }

    /// The messages whose lease ended, queued again (first). Callers hold ``cond``.
    func requeueEndedLeases() {
        let now = Date()
        queued = transfer.leased.filter { $0.until <= now }.map(\.message) + queued
        transfer.leased.removeAll { $0.until <= now }
    }

    /// The queued messages, taken by a collect: leased, when the test asks for leases. Callers hold ``cond``.
    func takeQueued() -> [RelayMessage] {
        requeueEndedLeases()
        let taken = queued
        queued.removeAll()
        if let lease = transfer.leaseFor { transfer.leased += taken.map { ($0, Date().addingTimeInterval(lease)) } }
        return taken
    }

    /// An ack ends a message's lease. Callers hold ``cond``.
    func acked(_ msgID: String) { transfer.leased.removeAll { $0.message.msgID == msgID } }

    /// An answer to a `device.list` this phone did not ask just now: sealed under the session, with the `re` of another
    /// request, and a list that does not hold this phone. It is no answer to the check's own request (§11.14.10).
    public func sendStrayDeviceList() {
        locked { try? reply("device.list", #"{"devices":[{"id":"dev-2","kind":"desktop","state":"active","name":"Work laptop"}]}"#, re: Ulid.new()) }
    }

    /// Called with the vault relay's deposit: true when it is refused as revoked. Callers hold ``cond``.
    func refusesDeposit() -> Bool {
        if transfer.revokesFin, responder != nil || transfer.finSeen {
            transfer.revokedDeposits += 1
            return true
        }
        guard transfer.revokesDeposits else { return false }
        transfer.revokedDeposits += 1
        return true
    }

    /// How many `device.list` requests reached the vault after an approval that took effect (never answered).
    public var deviceListsAfterTransfer: Int { locked { transfer.listRequests } }

    /// The new phone's `device.transfer.pending`: the SAS to compare, with the signer of its app when it has one (§11.7.1).
    public func sendTransferPending(transferID: String, name: String = "Pixel 10", sas: String = "042817", signer: String? = nil, signerChanged: Bool? = nil) {
        locked {
            var body = JsonBuilder().string("transfer_id", transferID).string("name", name).string("sas", sas)
            if let signer { body = body.string("signer", signer) }
            if let signerChanged { body = body.bool("signer_changed", signerChanged) }
            try? reply("device.transfer.pending", body.build())
        }
    }

    /// `device.transfer.create`, `.reject` and `.approve`, and `device.list`; then ``connectionsRequest(_:_:)``. Callers
    /// hold ``cond``.
    func transferRequest(_ m: Inner, _ body: JsonObject) throws {
        switch m.type {
        case "device.transfer.create": try transferCreate(m)
        case "device.transfer.reject":
            let id = try body.string("transfer_id")
            transfer.rejected.append(id)
            if transfer.open == id { transfer.open = nil }
            try reply(m.type, "{}", re: m.id)
        case "device.transfer.approve": try transferApprove(m, body)
        case "device.list": try deviceListRequest(m)
        default: try connectionsRequest(m, body)
        }
    }

    /// `device.list`: by the test's switch, else by the transfer's rules.
    private func deviceListRequest(_ m: Inner) throws {
        if let answer = transfer.listAnswer {
            switch answer {
            case .withoutThisPhone: return try reply(m.type, #"{"devices":[{"id":"dev-2","kind":"desktop","state":"active","name":"Work laptop"}]}"#, re: m.id)
            case .thisPhoneAsDesktop: return try reply(m.type, #"{"devices":[{"id":"dev-1","kind":"desktop","state":"active","name":""}]}"#, re: m.id)
            case .refused(let code): return try reply(m.type, "{}", re: m.id, error: code)
            }
        }
        // The vault removes the old app and its session at a completed approval: it cannot answer it any more.
        if transfer.approved, transfer.tookEffect {
            transfer.listRequests += 1
            return
        }
        try reply(m.type, #"{"devices":[{"id":"dev-1","kind":"app","state":"active","name":""},{"id":"dev-2","kind":"desktop","state":"active","name":"Work laptop"}]}"#, re: m.id)
    }

    private func transferCreate(_ m: Inner) throws {
        if transfer.open != nil { return try reply(m.type, "{}", re: m.id, error: "exists") }
        let id = Ulid.new()
        let exp = Date().addingTimeInterval(600)
        let link = try InviteQr(kind: .app, relay: vaultRelay.baseURL, claimID: Self.claimID(), hash: Randomness.bytes(32), key: Randomness.bytes(32), exp: UInt64(exp.timeIntervalSince1970)).link()
        transfer.open = id
        transfer.offers += 1
        try reply(m.type, #"{"transfer_id":"\#(id)","link":"\#(link)","exp":"\#(Timestamps.formatMillis(exp))"}"#, re: m.id)
    }

    /// vettid-vault's order (§6.7.1 step 3): the UTK spent, `signer_unconfirmed` before anything is counted, then the blob,
    /// the PIN and the password as an owner check; the CEK rotated and the answer `{"unlink":"after_new_unlock"}`.
    private func transferApprove(_ m: Inner, _ body: JsonObject) throws {
        guard let p = try opened(m, body) else { return }
        let seen = TransferApprovalSeen(transferID: (try? body.string("transfer_id")) ?? "", pin: (try? p.string("pin")) ?? "", password: (try? p.string("password")) ?? "", signer: try body.optString("signer"))
        transfer.approvals.append(seen)
        if let required = transfer.signerRequired, seen.signer != required {
            return try reply(m.type, "{}", re: m.id, error: "signer_unconfirmed")
        }
        guard try checkSecrets(m, pin: seen.pin, password: seen.password, blob: try body.optString("credential")) else { return }
        transfer.open = nil
        transfer.approved = true
        credentialVersion += 1
        try reply(m.type, transfer.earlierRelease ? "{}" : #"{"unlink":"after_new_unlock"}"#, re: m.id)
    }
}

// swiftlint:enable line_length
#endif
