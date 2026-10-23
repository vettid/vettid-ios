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
            keptCheckPending = true
            await endKeptTransfer()
        case .keep(let remainingMs):
            transferKeptSince = Date(timeIntervalSince1970: Double(at) / 1000)
            keptCheckPending = false
            keptTimer?.cancel()
            let sleep = config.keepSleep
            keptTimer = Task { @MainActor [weak self] in
                // A timer replaced before it began must not ask for its wait: the newest one is the one that runs.
                guard !Task.isCancelled else { return }
                do {
                    try await sleep(.milliseconds(remainingMs))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                // Not cancelled by the check it runs.
                self.keptTimer = nil
                await self.checkKeptTransfer()
            }
        }
    }

    /// What the end-of-keep check found (owner decisions of 2026-10-16 and 2026-10-23).
    enum KeptEndCheck: Equatable {
        /// The vault answered, and its list names this phone as its app.
        case listed
        /// The vault answered with a list that does not name this phone as an `app`: the only definite answer that erases
        /// (besides the vault's own `device.unlinked{transferred}`).
        case notListed
        /// No definite answer (owner decision, 2026-10-23): no answer within ``VaultManagerConfig/keptEndCheck``, the vault
        /// locked or a lock pending, any refusal or error, a cancellation, the app in or gone to the background (the wait's
        /// clock runs while it is suspended), a halt. Never erases: this phone keeps its keys, ``keptCheckPending`` says so,
        /// and the check is made again at each start and foreground, and after a pause, until the vault answers.
        case notChecked
    }

    /// What one probe of the vault found, before the check weighs the app's own state.
    enum KeptProbe: Equatable {
        case listed, notListed, timedOut, notRun
    }

    /// How long a check that did not run waits before it is made again while the app is in the foreground (chosen; not
    /// in the spec).
    nonisolated static let keptRetryAfter: Duration = .seconds(300)

    /// The 7 days are over (owner decisions of 2026-10-16 and 2026-10-23): a check with the vault over this phone's own
    /// session (``keptEndCheck()``). Listed: the transfer never took effect, this phone keeps its keys, the kept state goes
    /// and the member is told (``moveNotDone``), but only once the record has been written. Not listed (an answered list
    /// without this phone as an `app`): this phone's keys are removed. Not checked: nothing is decided and nothing erased;
    /// ``keptCheckPending`` stays true and the check is made again.
    func endKeptTransfer() async {
        guard !keptEnding else { return }
        keptEnding = true
        defer { keptEnding = false }
        guard record.value.transferApprovedAtMs != nil else { return }
        switch await keptEndCheck() {
        case .listed:
            keptCheckPending = false
            keptTimer?.cancel()
            keptTimer = nil
            // The record is read again after the wait: a lock during it moved the generation, and a write for the record
            // as it was before would be dropped. The member is told only when the write was made.
            let wrote = (try? record.update(since: record.generation) { $0.transferApprovedAtMs = nil; $0.transferKeepMs = nil }) == true
            guard wrote else { return scheduleKeptRetry() }
            transferKeptSince = nil
            moveNotDone = true
        case .notListed:
            guard !halted else { return }
            keptCheckPending = false
            wipeMovedAway = true
            try? await eraseThisPhone()
        case .notChecked:
            scheduleKeptRetry()
        }
    }

    /// The end of the keep is checked again after a pause, while the app is in the foreground; in the background the next
    /// return to the foreground does it (``onForeground()``).
    private func scheduleKeptRetry() {
        guard !backgrounded, !halted, record.value.transferApprovedAtMs != nil else { return }
        keptTimer?.cancel()
        let sleep = config.keepSleep
        keptTimer = Task { @MainActor [weak self] in
            do {
                try await sleep(Self.keptRetryAfter)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.keptTimer = nil
            await self.checkKeptTransfer()
        }
    }

    /// `device.list` sent over this phone's end-to-end session with the vault, opened and answered within
    /// ``VaultManagerConfig/keptEndCheck`` (as vettid-android's `withTimeout` covers `session()`), and only in the
    /// foreground: a check during which the app went to the background, or was halted, is ``KeptEndCheck/notChecked`` (the
    /// wait's clock runs while the app is suspended, so its timer would win on the return). The answer must be sealed under
    /// the session's keys (held only by the enclave and this phone) and answer this request's fresh id; the vault removes
    /// the old app and its session at a completed approval, so it cannot answer it any more.
    func keptEndCheck() async -> KeptEndCheck {
        guard !backgrounded, !halted else { return .notChecked }
        let began = moveFlags.book.lifecycle
        let limit = config.keptEndCheck
        let sleep = config.lockTiming.sleep
        let probe: KeptProbe
        do {
            probe = try await withThrowingTaskGroup(of: KeptProbe.self) { group in
                group.addTask { () async throws -> KeptProbe in await self.probeKeptEnd() }
                group.addTask { try await sleep(limit); return .timedOut }
                defer { group.cancelAll() }
                return try await group.next() ?? .timedOut
            }
        } catch {
            return .notChecked
        }
        guard !Task.isCancelled, !backgrounded, !halted, began == moveFlags.book.lifecycle else { return .notChecked }
        switch probe {
        case .listed: return .listed
        case .notListed: return .notListed
        // No answer (the vault locked, silent, slow): not a definite answer (owner decision, 2026-10-23).
        case .timedOut, .notRun: return .notChecked
        }
    }

    /// The probe: the session, the vault client and the list. Only an answered list is a verdict (``KeptProbe/listed``,
    /// ``KeptProbe/notListed``); everything else (a cancellation, a lock pending, the iPhone locked, a refusal or an error)
    /// is ``KeptProbe/notRun``.
    private func probeKeptEnd() async -> KeptProbe {
        do {
            let s = try await openSession()
            let api: VaultApi
            do {
                api = try openApi(s)
            } catch let f as VaultFailure where f.code == Self.codeLockPending {
                return .notRun
            }
            let list = try await api.deviceList()
            return KeptTransfer.stillTheApp(deviceList: list, deviceID: s.device.deviceID) ? .listed : .notListed
        } catch is CancellationError {
            return .notRun
        } catch let f as VaultFailure where f.kind == .phoneLocked || f.code == "halted" || f.code == "session_dropped" {
            return .notRun
        } catch {
            // A refusal or an error is not the vault's list: no definite answer (owner decision, 2026-10-23; vettid-android
            // erased on it, and changes to match).
            return .notRun
        }
    }

    /// "The move didn't finish" succeeded: this phone opened the vault with its own keys, so it is the vault's phone again.
    func clearKeptTransfer(since rec: Int) {
        guard record.value.transferApprovedAtMs != nil else { return }
        keptTimer?.cancel()
        keptTimer = nil
        _ = try? record.update(since: rec) { $0.transferApprovedAtMs = nil; $0.transferKeepMs = nil }
        transferKeptSince = nil
        keptCheckPending = false
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
    /// on the welcome screen (``wipeMovedAway``). Set before the event is handed to ``HolderWatch``; only ever set, never
    /// cleared by another event.
    func markMovedAway(_ m: VaultMessage) {
        let reason = VaultJSON.string(m.object, "reason")
        // Only ever set (as vettid-android does): another `device.unlinked` must not clear it mid-wipe.
        if record.value.transferApprovedAtMs != nil, reason == HolderPolicy.reasonTransferred { wipeMovedAway = true }
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
