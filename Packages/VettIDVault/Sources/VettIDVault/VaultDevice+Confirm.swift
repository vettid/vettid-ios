import Foundation
import VettIDCrypto

// Activation on confirmation, the responder half (VAULT-MESSAGING 0.87.0–0.88.1, §6.3.1 "Responder", "Devices and
// agents"), for the vault's rekeys of this device. The device activates at a verified `hs.fin` and queues `hs.confirm`
// under the new epoch in the same write. Its confirmed epoch (the newest the vault sent it anything but `hs.fin` under)
// keeps its rk and receive keys while not current, up to 48 days; a rekey under it is accepted as if it were current,
// and a message under it while it is not current brings `hs.confirm` again (at most once a minute, unless one is still
// in the outbox). While the current epoch is unconfirmed, `hs.confirm` goes again 12 days after the last one. After each
// epoch it activates the device sends `device.features` (§10.2). Mirrors vettid-vault `client/confirm.go`.
//
// Not here: rule E and §3.4.1's demotion (a device applies neither, §15 item 51), and the initiator half (a device starts
// no rekey with its vault).
extension VaultDevice {
    static let typeDeviceFeatures = "device.features"
    /// How long the confirmed epoch keeps its keys while not current (§6.3.1 table).
    static let confirmedKeysFor: TimeInterval = 48 * 86_400
    /// `hs.confirm` again for messages under the confirmed epoch: at most once a minute.
    static let reconfirmEvery: TimeInterval = 60
    /// (0.88.1) `hs.confirm` again 12 days after the last one while the current epoch is unconfirmed. Not scaled
    /// (§11.10.8).
    static let confirmResend: TimeInterval = 12 * 86_400

    /// The confirmed epoch's id: the recorded one, else the current epoch's. Callers hold ``mem``.
    private func confirmedIDLocked() -> [UInt8]? {
        if let c = st.vault?.confirmed { return try? Base64s.decodeStd(c) }
        return keyring.current()?.id
    }

    /// Whether [ep] is the confirmed epoch and still holds its rk (a rekey under it is accepted). Callers hold ``mem``.
    func isConfirmedLocked(_ ep: Epoch) -> Bool {
        st.vault != nil && ep.id == confirmedIDLocked() && ep.hasRK
    }

    /// Activates the vault's rekey epoch at its verified `hs.fin`. When the current epoch is the confirmed one, it stays
    /// the confirmed epoch with its rk and receive key; otherwise the current one is retired as before. Callers hold
    /// ``mem``; the caller queues ``queueConfirmed(_:)`` after it.
    func activateRekeyLocked(_ e: Epoch, _ t: Date) {
        if let cur = keyring.current(), cur.id == confirmedIDLocked() {
            if st.vault?.confirmed == nil { st.vault?.confirmed = cur.ctx }
            keyring.activateKeeping(e, now: t, until: t.addingTimeInterval(Self.confirmedKeysFor))
        } else {
            keyring.activate(e, now: t)
        }
    }

    /// After an activation: `hs.confirm` and `device.features` into the outbox, stored by the save that ends the handling,
    /// deposited after it. A failure to queue (no token, halted) is left to the 12-day re-send (``tickConfirm()``): the
    /// activation stands. Callers hold ``lock``.
    func queueConfirmed(_ t: Date) {
        try? queueConfirm(t, save: false)
        try? queueFeatures(save: false)
    }

    /// A message other than `hs.fin` opened under [ep]. Under the current epoch it confirms it: the previous confirmed
    /// epoch loses its rk and keeps its receive key for 16 days (§6.3.1 table). Under the confirmed epoch while it is not
    /// current, `hs.confirm` goes again. Callers hold ``lock``.
    func noteConfirmed(_ ep: Epoch, _ t: Date) {
        let again: Bool = mem.withLock {
            guard st.vault != nil else { return false }
            if keyring.current() === ep {
                if let c = st.vault?.confirmed {
                    if let id = try? Base64s.decodeStd(c), id != ep.id {
                        keyring.release(id, until: t.addingTimeInterval(Epoch.receiveKeyRetention))
                    }
                    st.vault?.confirmed = nil
                }
                return false
            }
            guard ep.id == confirmedIDLocked(), !st.outbox.contains(where: { $0.type == HsTypes.confirm }) else { return false }
            if let last = memory.reconfirmedAt, t.timeIntervalSince(last) < Self.reconfirmEvery { return false }
            memory.reconfirmedAt = t
            return true
        }
        if again { try? queueConfirm(t, save: false) }
    }

    /// (0.88.1) `hs.confirm` again 12 days after the last one queued while the current epoch is unconfirmed, unless one is
    /// still in the outbox. Callers hold ``lock``; [save]: false while a message is being handled (delivered after the
    /// lock), true otherwise (the entry is returned for the caller to deliver).
    @discardableResult
    func tickConfirmLocked(_ t: Date, save saves: Bool) -> OutboxEntry? {
        let due: Bool = mem.withLock {
            guard let v = st.vault, v.confirmed != nil, keyring.current() != nil else { return false }
            if st.outbox.contains(where: { $0.type == HsTypes.confirm }) { return false }
            return Double(Self.ms(t) - (v.confirmAtMs ?? 0)) / 1000 >= Self.confirmResend
        }
        return due ? try? queueConfirm(t, save: saves) : nil
    }

    /// ``tickConfirmLocked(_:save:)`` under the device lock, and the deposit of what it queued outside it (a transport
    /// failure leaves it in the outbox for the next flush).
    func tickConfirm() async {
        let e = await lock.withLock { tickConfirmLocked(now(), save: true) }
        if let e { try? await deliver(e) }
    }

    /// Queues `hs.confirm` (body `{}`, durable, not a request) and records when, in the same write. [save]: true outside
    /// a handling, where the caller delivers the entry returned; false inside one, delivered after the lock.
    @discardableResult
    private func queueConfirm(_ t: Date, save saves: Bool) throws -> OutboxEntry {
        let before: Int64? = mem.withLock {
            defer { st.vault?.confirmAtMs = Self.ms(t) }
            return st.vault?.confirmAtMs
        }
        do {
            let e = try enqueueLocked(
                id: nil, type: HsTypes.confirm, body: VaultJSON.empty, re: nil, status: nil, exp: nil, save: saves
            )
            if !saves { afterLock { [self] in try? await deliver(e) } }
            return e
        } catch {
            mem.withLock { st.vault?.confirmAtMs = before }
            throw error
        }
    }

    /// Queues `device.features` with this app's list (§10.2).
    func queueFeatures(save saves: Bool) throws {
        let body = JsonBuilder().raw("features", JsonBuilder.array(DeviceFeatures.all.map(JsonBuilder.quote))).bytes()
        let e = try enqueueLocked(id: nil, type: Self.typeDeviceFeatures, body: body, re: nil, status: nil, exp: nil, save: saves)
        afterLock { [self] in try? await deliver(e) }
    }
}
