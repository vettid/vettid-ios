import Foundation
import VettIDAltChan
import VettIDVault

// The old phone's keys after a transfer it approved, and "Finish the move" on the new phone (VAULT-MESSAGING §11.14.10;
// owner decisions of 2026-10-15 and 2026-10-16). Mirrors vettid-android `VaultManager`'s `checkKeptTransfer`,
// `endKeptTransfer`, `stillTheVaultsApp`, `clearKeptTransfer` and `finishMove`.
extension VaultManager {
    // MARK: - The old phone keeps its keys

    /// At every start, on every return to the foreground, and when the 7 days run out while the process lives: a transfer
    /// approved 7 days ago or more ends here (the old phone's keys go, §11.14.10); before that, ``transferKeptSince`` tells
    /// the shell to say "Finish the move on your new phone", and a timer runs to the end. A clock behind the approval counts
    /// the 7 days from now, stored, so that later checks do not extend them again (``KeptTransfer/start(approvedAtMs:nowMs:)``).
    public func checkKeptTransfer() async {
        let rec = record.generation
        guard let stored = record.value.transferApprovedAtMs else { return }
        let now = nowMs
        let at = KeptTransfer.start(approvedAtMs: stored, nowMs: now)
        if at != stored { _ = try? record.update(since: rec) { $0.transferApprovedAtMs = at } }
        switch KeptTransfer.decide(approvedAtMs: at, nowMs: now, keepMs: record.value.transferKeepMs ?? KeptTransfer.keepPeriodMs) {
        case .erase:
            keptTimer?.cancel()
            keptTimer = nil
            await endKeptTransfer()
        case .keep(let remainingMs):
            transferKeptSince = Date(timeIntervalSince1970: Double(at) / 1000)
            keptTimer?.cancel()
            let sleep = config.keepSleep
            keptTimer = Task { @MainActor [weak self] in
                do {
                    try await sleep(.milliseconds(remainingMs))
                } catch {
                    return
                }
                guard let self else { return }
                // Not cancelled by the check it runs.
                self.keptTimer = nil
                await self.checkKeptTransfer()
            }
        }
    }

    /// The 7 days are over (owner decision 2026-10-16): before erasing, ONE check with the vault over this phone's own
    /// session (``stillTheVaultsApp()``). Confirmed: the transfer never took effect, this phone keeps its keys, the kept
    /// state goes and the member is told (``moveNotDone``). Anything else (the vault no longer lists this phone, a refusal,
    /// no answer within ``VaultManagerConfig/keptEndCheck``, any failure): this phone's keys are removed, as before. Never
    /// retried: the bound stays 7 days.
    func endKeptTransfer() async {
        guard !keptEnding else { return }
        keptEnding = true
        defer { keptEnding = false }
        let rec = record.generation
        guard record.value.transferApprovedAtMs != nil else { return }
        if await stillTheVaultsApp() {
            keptTimer?.cancel()
            keptTimer = nil
            _ = try? record.update(since: rec) { $0.transferApprovedAtMs = nil; $0.transferKeepMs = nil }
            transferKeptSince = nil
            moveNotDone = true
        } else {
            wipeMovedAway = true
            try? await eraseThisPhone()
        }
    }

    /// `device.list` sent over this phone's end-to-end session with the vault, answered within
    /// ``VaultManagerConfig/keptEndCheck``: true only when the answer lists this phone as the vault's app
    /// (``KeptTransfer/stillTheApp(deviceList:deviceID:)``). The answer must be sealed under the session's keys (held only
    /// by the enclave and this phone) and answer this request's fresh id; the vault removes the old app and its session at
    /// a completed approval, so it cannot answer it any more.
    func stillTheVaultsApp() async -> Bool {
        let limit = config.keptEndCheck
        let sleep = config.lockTiming.sleep
        do {
            let s = try await openSession()
            let id = s.device.deviceID
            let api = try openApi(s)
            let list: [DeviceEntry]? = try await withThrowingTaskGroup(of: [DeviceEntry]?.self) { group in
                group.addTask { try await api.deviceList() }
                group.addTask { try await sleep(limit); return nil }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            return KeptTransfer.stillTheApp(deviceList: list, deviceID: id)
        } catch {
            // Any failure is "not confirmed".
            return false
        }
    }

    /// "The move didn't finish" succeeded: this phone opened the vault with its own keys, so it is the vault's phone again.
    func clearKeptTransfer(since rec: Int) {
        guard record.value.transferApprovedAtMs != nil else { return }
        keptTimer?.cancel()
        keptTimer = nil
        _ = try? record.update(since: rec) { $0.transferApprovedAtMs = nil; $0.transferKeepMs = nil }
        transferKeptSince = nil
        movedBack = true
    }

    /// How long this phone keeps its keys after approving a transfer, for the texts: the period the approval started, stored
    /// with it (``LocalAccount/transferKeepMs``: a scale learnt later does not change it), else 7 days.
    public var transferKeepSeconds: Int64 { (record.value.transferKeepMs ?? KeptTransfer.keepPeriodMs) / 1000 }

    public func acknowledgeMovedBack() { movedBack = false }

    public func acknowledgeMoveNotDone() { moveNotDone = false }

    public func acknowledgeMovedAway() {
        wiper?.acknowledgeMovedAway()
        movedAway = false
    }

    /// The `device.unlinked{transferred}` that ends a kept transfer is also an old phone's removal of its keys: it says so
    /// on the welcome screen (``wipeMovedAway``). Set before the event is handed to ``HolderWatch``, and cleared when the
    /// event proves nothing.
    func markMovedAway(_ m: VaultMessage) {
        let reason = VaultJSON.string(m.object, "reason")
        wipeMovedAway = record.value.transferApprovedAtMs != nil && reason == HolderPolicy.reasonTransferred
    }

    /// The vault's truth about this phone's transfer, read at the start of each session: the 7 days are checked again.
    func resumeKeptTransfer() {
        guard record.value.transferApprovedAtMs != nil else { return }
        Task { @MainActor [weak self] in await self?.checkKeptTransfer() }
    }

    // MARK: - Finish the move (the new phone)

    /// The runner of "Finish the move" (VAULT-MESSAGING §11.14.10 step 4), over [ref]'s manager.
    static func finishMoveRunner(_ ref: ManagerRef, hold: Duration, sleep: @escaping LockSleep) -> FinishMoveRunner {
        FinishMoveRunner(
            hold: hold, sleep: sleep,
            lock: { try await ref.manager?.lock() },
            unlock: { pin, taken in
                guard let m = ref.manager else { return .failed(.other, code: "session_dropped") }
                return await m.finishMoveUnlock(pin: pin, taken: taken)
            },
            // Every lock and every wipe moves one of the two.
            generation: { (ref.manager?.lockGeneration ?? 0) + (ref.manager?.record.generation ?? 0) },
            signedOut: { ref.manager?.phase == .signedOut },
            onOutcome: { r in if r == .success { ref.manager?.finishMoveRunner.clearFailure() } },
            // Not after a lock, a reset or a wipe: the rotate offer is the record of the phone that is open now.
            onOpened: { _ in
                guard let m = ref.manager else { return }
                m.setRotateOffer(true, since: m.record.generation)
            }
        )
    }

    /// The unlock of "Finish the move" with the PIN as the screen took it: refused once which PIN the vault expects moved
    /// since (checked again after the run's own lock, and right before the request is posted).
    func finishMoveUnlock(pin: String, taken: Int?) async -> UnlockAttempt {
        if let moved = pinTakenBefore(taken) { return .failed(moved.kind, code: moved.code) }
        var route = UnlockRoute()
        route.pinTaken = taken
        return await unlockOutcome(pin: pin, options: UnlockOptions(), route: route).attempt
    }

    /// Which PIN the vault expects (``PhoneSecrets/pinGeneration``), for a screen's keypad.
    public var pinGeneration: Int { phoneSecrets.pinGeneration }

    public var finishingMove: Bool { finishMoveRunner.finishing }

    public var finishMoveFailure: FailureKind? { finishMoveRunner.failure }

    public func acknowledgeFinishMoveFailure() { finishMoveRunner.clearFailure() }

    /// "Finish the move" (release R, §11.14.10): `vault.lock`, then `vault.unlock` with this phone's own secret, which reads
    /// the stored header and state and so proves that both writes of the transfer are durable. Refused while a change is on
    /// its way or unresolved, or the PIN uncertain (VAULT-MESSAGING 0.46.0 §11.14.9 step 2), with the hold's text; a PIN
    /// taken before a change neither locks the vault nor is sent. Then it runs in the ``FinishMoveRunner``: **once asked
    /// for, it completes**, also when the screen that asked goes away.
    public func finishMove(pin: String, taken: Int?) async throws -> UnlockAttempt {
        let taken = taken ?? phoneSecrets.pinGeneration
        if let hold = moveHold() { throw hold }
        if let moved = pinTakenBefore(taken) { return .failed(moved.kind, code: moved.code) }
        return try await finishMoveRunner.run(pin: pin, taken: taken)
    }

    public func finishMove(pin: String) async throws -> UnlockAttempt { try await finishMove(pin: pin, taken: nil) }

    /// Recomputes ``finishMoveHold`` from the change gate (``moveHold()``): called wherever a change starts or ends, or the
    /// PIN becomes uncertain or settles.
    func refreshFinishMoveHold() {
        let hold = moveHold()?.kind
        if finishMoveHold != hold { finishMoveHold = hold }
    }
}
