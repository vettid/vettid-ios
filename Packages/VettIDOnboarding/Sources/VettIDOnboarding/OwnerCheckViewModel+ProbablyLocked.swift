import Foundation
import VettIDData

// Probably locked (VAULT-MESSAGING 0.73.0–0.73.2 §3.6.5; IOS-PLAN 0.1.49): an estimate of 0 tries left shows no fields and
// no check while the vault's state is read again; an unanswered check above 0 says it may have counted. As vettid-android
// `OwnerCheckViewModel`.
extension OwnerCheckViewModel {
    /// The waits before each read while the vault is probably locked: at once, then about 5 s, 15 s, 1 min and 3 min after
    /// the start; each counted from the end of the read before.
    static let readGaps: [Duration] = [.zero, .seconds(5), .seconds(10), .seconds(45), .seconds(120)]

    /// A check with no answer, tries still estimated to be left: one re-read of the vault's state (nil: none made). Nothing
    /// entered is kept past the check's answer, so the entries go before it, not after.
    func rereadIfUnanswered(_ r: OwnerCheckOutcome) async -> VaultProbe? {
        guard Self.needsReread(r) else { return nil }
        state.password = ""
        if !(state.pinKept && Self.keepsPin(r)) { state.pin = "" }
        return await repo.probeVault(lockCauseKnown: false)
    }

    /// An answer that leaves the app unable to tell whether the vault locked: the estimate of tries left is 0 or less.
    static func needsWatch(_ r: OwnerCheckOutcome) -> Bool {
        switch r {
        case .badPassword(let left, true), .badPin(let left, true): (left ?? 0) <= 0
        case .failed(_, _, let left): r.isUnanswered && (left ?? 1) <= 0
        default: false
        }
    }

    /// The check was not answered and tries are still estimated to be left: the vault's state is read once, with no check.
    static func needsReread(_ r: OwnerCheckOutcome) -> Bool {
        guard case .failed(_, _, let left) = r else { return false }
        return r.isUnanswered && (left ?? 0) > 0
    }

    /// The message after [r] and the re-read [probe] that followed it (nil: none was made).
    static func message(after r: OwnerCheckOutcome, _ probe: VaultProbe?) -> OwnerCheckMessage? {
        switch probe {
        // A lock found: the locked line, nothing more.
        case .locked?: return nil
        case .noAnswer?:
            if case .failed(_, _, let left?) = r { return .maybeCounted(atLeast: left) }
            return message(r)
        // The vault answered: the check did not go through, and the screen says so, with the real count.
        case .open?, nil: return message(r)
        }
    }

    /// What an outcome from before the screen opened (the unlock's check) leaves to do.
    func followUp(_ r: OwnerCheckOutcome) {
        if repo.lockedByOwnerCheck { return }
        if Self.needsWatch(r) {
            beginWatch()
        } else if Self.needsReread(r) {
            followUpTask = launch { [self] in
                // A lock found here has no known cause.
                let probe = await repo.probeVault(lockCauseKnown: false)
                guard !Task.isCancelled else { return }
                state.message = Self.message(after: r, probe)
            }
        }
    }

    /// The first text, no fields and no check: the reads start at once.
    func beginWatch() {
        ticker?.cancel()
        state.pin = ""
        state.password = ""
        state.pinKept = false
        state.unlockedWrong = nil
        state.unlockedOpen = false
        state.waitSeconds = 0
        state.message = nil
        state.busy = false
        runReads()
    }

    public func checkAgain() {
        if state.watch == .silent { runReads() }
    }

    /// The reads at once, then after about 5 s, 15 s, 1 min and 3 min, one at a time: the gaps count from the end of the
    /// read before, so a slow read moves the later ones.
    func runReads() {
        watchTask?.cancel()
        state.watch = .checking
        let wait = readWait
        // Held weakly between the reads: a screen that went away ends them (``deinit``).
        watchTask = launch { [weak self] in
            for gap in Self.readGaps {
                do {
                    try await wait(gap)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                if await readOnce() { return }
            }
            guard let self, !Task.isCancelled, state.watch == .checking else { return }
            state.watch = .silent
        }
    }

    /// A reconnect or a return to the foreground: one read now, or after the one running. Never more than one waits.
    /// Not while the member's lock is on its way.
    func readNowIfWatching() {
        guard state.watch != .none, !state.locking, triggerTask == nil else { return }
        triggers += 1
        let mine = triggers
        triggerTask = launch { [weak self] in
            _ = await self?.readOnce()
            // A newer trigger's handle (after ``stopReads()``) stays.
            if let self, triggers == mine { triggerTask = nil }
        }
    }

    /// Ends every read in progress or waiting (the screen's start or end, the member's lock).
    func stopReads() {
        watchTask?.cancel()
        triggerTask?.cancel()
        followUpTask?.cancel()
        watchTask = nil
        triggerTask = nil
        followUpTask = nil
    }

    /// One read while probably locked (never a check), after the one before it ended: `vault.status` answering means the
    /// vault is open, and the ordinary check returns with the count from the answer; a lock found shows the lock text (the
    /// flag comes from the repository). True: settled.
    private func readOnce() async -> Bool {
        let before = lastRead
        let mine = Task { @MainActor [self] () -> Bool in
            await before?.value
            guard state.watch != .none else { return true }
            switch await repo.probeVault(lockCauseKnown: true) {
            case .open, .locked:
                state.watch = .none
                state.message = nil
                return true
            case .noAnswer:
                return false
            }
        }
        lastRead = Task { _ = await mine.value }
        return await withTaskCancellationHandler { await mine.value } onCancel: { mine.cancel() }
    }
}
