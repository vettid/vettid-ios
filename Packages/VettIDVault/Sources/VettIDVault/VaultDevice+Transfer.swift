import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDRelay

/// A scanned or pasted code is not a direct-transfer code (§6.7.1: a pairing QR of kind `p`, bundle kind `app`), or has
/// expired. Mirrors vettid-android `NotATransferCodeException`.
public struct NotATransferCode: Error, Equatable, Sendable, CustomStringConvertible {
    public let expired: Bool

    public init(expired: Bool = false) {
        self.expired = expired
    }

    public var description: String { expired ? "vault client: the transfer code has expired" : "vault client: not a transfer code" }
}

// A direct transfer, the new app's side (VAULT-MESSAGING §6.7.1). Mirrors vettid-android `VaultDevice.startTransfer`,
// `awaitTransfer` and `abandonTransfer`.
extension VaultDevice {
    /// What the new phone decides from the bundle before its `hs.init` is built: its [capabilities] (empty when it has
    /// none) and [timeScale] (1 when it has none). Returns the new phone key's secret of epoch 1 for release R's `hs.init`
    /// (32 bytes; zeroed once the `hs.init` is sealed), or nil for the earlier one. It may throw, and then nothing is sent:
    /// a bundle whose release or time scale this build does not accept (IOS-PLAN ID8; STAGING-TIME-SCALE §4 item 4) is
    /// refused here, before the secret is asked for.
    public typealias TransferSecretFor = @Sendable (_ capabilities: [String], _ timeScale: UInt64) async throws -> [UInt8]?

    /// Starts a direct transfer to this phone from the old app's QR or link (§6.7.1), as vettid-vault's `PairAttested`:
    /// fetches the claim from the link's relay, checks it against the QR, pins the vault from the bundle and sends `hs.init`
    /// (purpose app, ctx = the bundle's invite id) with the device attestation over the §11.7 challenge (the `hs.init` id,
    /// an empty vault id and its `ts`), the app key, and release R's unlock secret. The vault answers with `hs.resp` at
    /// once; this device sends `hs.fin`, and the SAS appears in ``pairingSas``. Returns when `hs.init` is sent. Honours
    /// task cancellation: the claim's fetch and the deposit are cancelled with the task.
    public func startTransfer(link: String, attester: any Attester, unlockSecretFor: TransferSecretFor) async throws {
        let q: InviteQr
        do {
            q = try InviteQr.parseLink(link)
        } catch {
            throw NotATransferCode()
        }
        guard q.kind == .app else { throw NotATransferCode() }
        guard now() < Date(timeIntervalSince1970: TimeInterval(q.exp)) else { throw NotATransferCode(expired: true) }
        let blob = try await relayFor(q.relay).getClaim(q.claimID)
        try Task.checkCancellation()
        try await lock.withLock {
            guard mem.withLock({ st.deviceID == nil }) else { throw VaultStateError(message: "already paired with a vault") }
            let t = now()
            let b: InviteBundle
            do {
                b = try InviteBundle.open(blob, qr: q, now: t)
            } catch let e as CryptoError where e.kind == .time {
                throw NotATransferCode(expired: true)
            }
            guard b.kind == .app else { throw NotATransferCode() }
            var unlockSecret = try await unlockSecretFor(b.capabilities ?? [], b.timeScaleOrReal)
            defer { if unlockSecret != nil { Bytes.wipe(&unlockSecret!) } }
            mem.withLock {
                setVault(b.vault)
                st.vaultID = nil
                sas = nil
            }
            let at = Date(timeIntervalSince1970: Double(Self.ms(t)) / 1000)
            let id = Ulid.new(at)
            // A second code scanned while a transfer is open: the key the first one attested can no longer be bound.
            if let old = mem.withLock({ alt().transferAttestKeyID }) { try? attester.discard(keyID: old) }
            let attest = try attester.attest(try AltChannel.devattChallenge(requestID: id, vaultID: "", ts: Timestamps.formatMillis(at)))
            // A new attestation is a new key (§11.7.1).
            let profile = JsonBuilder().string("name", mem.withLock { st.name }).bytes()
            mem.withLock {
                st.signerSeen = false
                var a = alt()
                a.transferAttestKeyID = attest.iosKeyID
                setAlt(a)
            }
            // §6.2, §6.7.1 (0.15.0): a transfer's hs.init carries the new app's app key.
            do {
                try await startInit(
                    purpose: .app, ctx: b.inviteID, depositToken: b.token, profile: profile, at: at, deviceAttest: attest, id: id,
                    apiKey: secrets.apiKey, unlockSecret: unlockSecret
                )
                try save()
            } catch {
                discardFailedTransfer(attest, attester)
                throw error
            }
        }
    }

    /// The `hs.init` could not be sent: the key it attested is bound by no vault (IOS-PLAN §6.2), and the handshake and the
    /// pinned vault go with it.
    private func discardFailedTransfer(_ attest: DeviceAttest, _ attester: any Attester) {
        if let key = attest.iosKeyID { try? attester.discard(keyID: key) }
        dropPairing()
        mem.withLock {
            st.vault = nil
            var a = alt()
            a.transferAttestKeyID = nil
            setAlt(a)
        }
    }

    /// The SAS of the pairing handshake, once the vault's `hs.resp` checked out (§6.3): at once when it is there, else when
    /// it arrives. **Honours task cancellation** (``CancellationError``); the caller bounds the wait (60 s, §6.7.1 step 2).
    public func awaitPairingSas() async throws -> String {
        let stream = sasBroadcast.stream()
        if let s = pairingSas { return s }
        for await s in stream { return s }
        throw CancellationError()
    }

    /// The `user_guid` of a transfer's `device.paired` that was applied and whose take-over is not completed.
    public var transferUserGuid: String? { mem.withLock { st.transferUserGuid } }

    /// The take-over is completed: the kept `user_guid` goes.
    public func transferCompleted() async throws {
        try await lock.withLock {
            mem.withLock { st.transferUserGuid = nil }
            try save()
        }
    }

    /// Waits for the transfer's `device.paired` (the old app's approval completes the transfer, §6.7.1) or
    /// `device.pair.rejected` (``PairingRejected``). Returns the member's `user_guid` from it (0.17.0), which this phone's
    /// unlocks need, or nil when the vault sent none (a release before 0.17.0): the transfer is complete either way.
    public func awaitTransfer(timeout: TimeInterval) async throws -> String? {
        try await awaitPaired(timeout: timeout)
    }

    /// Drops a transfer this device started and has not completed (left the screen, timed out): the handshake, the pinned
    /// vault and the attested key's record. The key itself is the caller's to discard (``AltState/transferAttestKeyID``,
    /// read before this).
    /// False, and nothing dropped, when the transfer is paired: the pending epoch-1 secret is then this phone's.
    @discardableResult
    public func abandonTransfer() async throws -> Bool {
        try await lock.withLock {
            let changed: Bool = mem.withLock { st.deviceID == nil }
            guard changed else { return false }
            dropPairing()
            mem.withLock {
                st.vault = nil
                sas = nil
                var a = alt()
                a.transferAttestKeyID = nil
                setAlt(a)
            }
            try save()
            return true
        }
    }

    // MARK: - The old app: the renewal of its standing token (§11.14.10)

    /// Renews the standing token this device issued to the vault for its own mailbox: a fresh 30-day token in
    /// `relay.token.issued{kind: "standing"}`, deposited to the vault's mailbox, returning once the relay answered `201`.
    /// The previous token's `jti` is not denylisted. Throws when the renewal could not be deposited (the caller goes on).
    public func renewStandingToken() async throws {
        try await lock.withLock {
            let before = Set(mem.withLock { st.outbox.map(\.id) })
            do {
                let tok = try mintForVault()
                _ = try await sendLocked(id: nil, type: "relay.token.issued", body: Self.standing(tok), re: nil, status: nil, exp: nil)
            } catch {
                // A renewal that failed is not kept for a later flush: it would go out after the approval, whose token it is not.
                mem.withLock { st.outbox.removeAll { $0.type == "relay.token.issued" && !before.contains($0.id) } }
                try? save()
                throw error
            }
        }
    }

    // MARK: - The new app: one collect before the drop (§11.14.10 rule 5)

    /// One collect of this device's mailbox (`wait=0`, `max` at its cap, RELAY-PROTOCOL §6.3), bounded by [timeout] seconds
    /// in all, its transport retries included: each message is handled as the collector handles it and acked. A
    /// `device.paired{transfer}` it brings is then found by ``awaitTransfer(timeout:)``. Throws when the collect fails or
    /// times out; a task that is cancelled stops it.
    public func collectOnce(
        timeout: TimeInterval = 30, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        let own = own
        let messages: [RelayMessage] = try await withThrowingTaskGroup(of: [RelayMessage]?.self) { group in
            group.addTask { try await own.collect(wait: 0, max: RelayClient.maxCollect) }
            group.addTask {
                try await sleep(.seconds(timeout))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let found = first else {
                throw VaultStateError(message: "no collect within \(Int(timeout)) s")
            }
            return found
        }
        for m in messages {
            do {
                try await handle(m)
            } catch is LeaveUnacked {
                continue
            }
            try? await own.ack(m.msgID)
        }
    }
}
