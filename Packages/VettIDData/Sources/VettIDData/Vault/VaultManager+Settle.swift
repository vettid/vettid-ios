import Foundation
import VettIDRelay
import VettIDVault

// The settlement window of a transfer to this phone (VAULT-MESSAGING 0.85.2 §11.14.10 rule 5, owner decisions a and a/a
// of 2026-11-05; IOS-PLAN 0.1.64): past its deadline the new phone keeps collecting its mailbox for the relay's visibility
// timeout + the long-poll cap + 5 s before it drops the transfer, because a collect held by a killed app can have been
// handed `device.paired` and lease it for that long (RELAY-PROTOCOL §6.3). Mirrors vettid-android's settlement window.
extension VaultManager {
    /// The code of a transfer whose session ended during the window (`mailbox_unknown` for its mailbox, or the app signed
    /// out or wiped, §11.14.10 rule 5): reported as ended, never as dropped.
    public nonisolated static let codeTransferSessionEnded = "transfer_session_ended"
    /// How long after the start of the `hs.init` the vault takes an approval (§6.7, 0.10.4): no abandon from then on.
    nonisolated static let vaultApprovalWindow: TimeInterval = 600
    /// The relay's visibility timeout when the registration gives none, and the clamp of an advertised one (§11.14.10
    /// rule 5: 60 s if absent, clamped to 0 to 300).
    nonisolated static let defaultVisibility: TimeInterval = 60
    nonisolated static let maxVisibility: TimeInterval = 300
    /// The longest long poll of the window (RELAY-PROTOCOL §6.3's `wait` cap), and the window's margin over the lease.
    nonisolated static let windowPoll: TimeInterval = 25
    nonisolated static let windowMargin: TimeInterval = 5
    /// What a long poll of the window leaves of the time left, to handle what it brings (rule 5: `wait` is min(25, time
    /// left − 5 s)).
    nonisolated static let handlingMargin: TimeInterval = 5
    /// How much longer than its `wait` a collect of the window is bounded: more than the transport's own long-poll timeout
    /// (60 s; rule 5: longer than `wait` + 10 s), so that the window never cancels a request the relay may be answering,
    /// which would leave what it was handed leased to a dead request. Each collect is one attempt (the window retries
    /// itself), so no retry of the relay client's runs into the bound (chosen; not in the spec).
    nonisolated static let collectSlack: TimeInterval = 70
    /// The bound of the registration that gives the relay's visibility timeout; past it, the default (chosen; not in the
    /// spec: a relay that answers `retry_after` must not hold the window).
    nonisolated static let limitsBound: Duration = .seconds(10)
    /// A gap of the monotonic clock between two ticks of a window's heartbeat that counts as a freeze (chosen; the shared
    /// rule with Android #307, the erratum to follow).
    nonisolated static let freezeGap: TimeInterval = 10
    /// How long after a lease's end the last collect it holds goes out: a send time is taken right before each attempt
    /// goes out, before its connection's DNS, TCP and TLS, so the request may reach the relay that much later (chosen; the
    /// shared rule with Android #307, the erratum to follow).
    nonisolated static let holdMargin: TimeInterval = 15
    /// How often a window kept alive in the background (a call, say) collects (chosen; not in the spec).
    nonisolated static let backgroundCollectPause: TimeInterval = 15

    /// How far past its first end a window's end may move, for a visibility timeout of [visibility] (clamped): the lease
    /// of a request cut up to the end of the window's last round (the long-poll cap and both margins) still ends inside
    /// it (chosen; the shared rule with Android #307, the erratum to follow).
    nonisolated static func maxEndPastFirst(visibility: TimeInterval) -> TimeInterval {
        visibility + windowPoll + handlingMargin + windowMargin
    }

    /// How long the collects before the drop go on: the relay's visibility timeout [visibility], the long-poll cap and a
    /// margin (90 s for a relay's 60 s). A `device.paired` that a killed app's long poll was handed, as late as the long
    /// poll allows, is leased to it for at most that long, and then reappears.
    nonisolated static func settleWindow(visibility: TimeInterval?) -> TimeInterval {
        min(max(visibility ?? defaultVisibility, 0), maxVisibility) + windowPoll + windowMargin
    }

    /// Whether the window of collects before the drop has ended (set by its timer, read by the loop).
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var value: Bool { lock.withLock { on } }
        func set() { lock.withLock { on = true } }
    }

    /// How the window of collects before the drop ended.
    enum WindowEnd: Sendable {
        case paired(String?)
        case rejected
        /// The transfer's session ended: `mailbox_unknown` ([drop]: its dead handshake goes), or the app signed out or
        /// wiped (nothing is written: the wipe or the sign-out has it).
        case ended(drop: Bool)
        case nothing
    }

    /// The collects before the drop: collects of the mailbox for ``settleWindow(visibility:)``
    /// (``VaultManagerConfig/transferWindowSleep``), until a `device.paired{transfer}` comes (it is applied), a
    /// `device.pair.rejected` (at once) or the session ends (at once). Long polls sized from the time left, or `wait=0`
    /// collects while the device's own collector long-polls; none is ever cancelled while out (``collectSlack``). A collect
    /// that fails is tried again after a pause (``VaultManagerConfig/transferRetrySleep``). After the window, one `wait=0`
    /// collect, and a round of the collector that was out then is waited for, so that what it took is handled before the
    /// decision. The window is the manager's, not its caller's: a screen that goes away does not cut it; only the process
    /// ending does (``cutSettleWindow()``). A cut collect, a freeze or a background during it moves its end out, within a
    /// cap (``WindowClock``; rule 5 says so of an app stopped during the window: a suspended app's collects were cut, and
    /// their leases may still run).
    func collectBeforeDrop(_ d: VaultDevice) async -> WindowEnd {
        let window = Task { @MainActor [self] in await collectWindow(d) }
        moveFlags.book.settleWindow = window
        defer { moveFlags.book.settleWindow = nil }
        return await window.value
    }

    private func collectWindow(_ d: VaultDevice) async -> WindowEnd {
        let visibility = await windowVisibility(d)
        let clock = WindowClock(visibility: visibility, backgrounds: moveFlags.book.backgrounds, background: backgrounded)
        clock.start(self, d)
        defer { clock.stop() }
        let sessionEnds = moveFlags.book.sessionEnds
        var failures = 0
        while !Task.isCancelled {
            // Signed out or wiped meanwhile (every device forgotten): the session this window collects for is gone. A
            // background ends the session too, and the foreground takes it back: that is no end of the transfer's.
            if moveFlags.book.sessionEnds != sessionEnds { return .ended(drop: false) }
            clock.follow(self, d)
            let last = clock.over
            await clock.waitForFinalCollect(self)
            let left = clock.until - config.uptime() - Self.handlingMargin
            let wait = last || collectorRuns(d) ? 0 : min(Self.windowPoll, max(left, 0)).rounded(.down)
            switch await windowCollect(d, wait: wait, last: last, clock: clock) {
            case .collected: failures = 0
            case .failed: failures += 1
            case .gone: return .ended(drop: true)
            }
            // A wipe or a sign-out while the collect was out: what it brought is not acted on.
            if moveFlags.book.sessionEnds != sessionEnds { return .ended(drop: false) }
            if last { await collectorRound(session?.device ?? d) }
            let found = await pairedOrRejected(d)
            if case .nothing = found {} else { return found }
            // Decided only if nothing cut the last collects: a background (it stops the collector, whose long poll may have
            // been handed the pairing) or a freeze during them moves the end out first, within its cap.
            if last, clock.dropsAfterFinalCollect(self, d) {
                // Nil: the look's collect was cut with the one more unused, and it goes (held) before the drop.
                if let end = await lastLook(d, clock: clock, sessionEnds: sessionEnds) { return end }
                continue
            }
            await pauseBetweenCollects(failures: failures, wait: wait)
        }
        return await pairedOrRejected(d)
    }

    /// Before the drop: while the app is in the background (nothing is decided there), a `wait=0` collect every
    /// ``backgroundCollectPause``, and back in the foreground after a background since the last collect went (it stopped
    /// the collector), one more; none of them moves the end or gives another last collect (chosen; the shared rule with
    /// Android #307, the erratum to follow), except that a look's collect that is cut or refused while the one more last
    /// collect is unused uses it: nil is returned, and the window goes back for that collect (held) before the drop. Then
    /// the drop, unless a `device.paired` or a refusal came, or the session ended meanwhile (a wipe or a sign-out since
    /// [sessionEnds], or `mailbox_unknown`).
    private func lastLook(_ d: VaultDevice, clock: WindowClock, sessionEnds: Int) async -> WindowEnd? {
        // A hold raised during the one more last collect is waited for first, and one `wait=0` look follows it.
        let held = await clock.holdAfterExtra(self)
        let waited = clock.backgroundSinceFinal(self)
        while backgrounded, !Task.isCancelled {
            await backgroundPause()
            switch await lookOnce(d, clock: clock, sessionEnds: sessionEnds) {
            case .ends(let end): return end
            case .again: return nil
            case nil: break
            }
        }
        if waited || held {
            switch await lookOnce(d, clock: clock, sessionEnds: sessionEnds) {
            case .ends(let end): return end
            case .again: return nil
            case nil: break
            }
        }
        return await pairedOrRejected(d)
    }

    /// How a look ended: with the window's end, or with the one more last collect to make.
    private enum Look {
        case ends(WindowEnd)
        case again
    }

    /// One `wait=0` collect of the last look, and what it ends with, if anything.
    private func lookOnce(_ d: VaultDevice, clock: WindowClock, sessionEnds: Int) async -> Look? {
        if moveFlags.book.sessionEnds != sessionEnds { return .ends(.ended(drop: false)) }
        // As the last collect: a refusal of it (429, a stale signature) uses the one more too.
        if case .gone = await windowCollect(d, wait: 0, last: true, clock: clock) { return .ends(.ended(drop: true)) }
        if moveFlags.book.sessionEnds != sessionEnds { return .ends(.ended(drop: false)) }
        let found = await pairedOrRejected(d)
        guard case .nothing = found else { return .ends(found) }
        return clock.redoneAfterLook(self, d) ? .again : nil
    }

    /// Between collects: a pause after a failure (1 s, doubled, at most 8 s), or while the collector long-polls; in the
    /// background, ``backgroundCollectPause``.
    private func pauseBetweenCollects(failures: Int, wait: TimeInterval) async {
        if backgrounded { return await backgroundPause() }
        guard failures > 0 || wait == 0 else { return }
        let seconds = failures > 0 ? min(Double(1 << min(failures - 1, 3)), 8) : 1
        moveFlags.book.windowPauseSeconds = seconds
        try? await config.transferRetrySleep(.seconds(seconds))
    }

    /// How a collect of the window ended (`gone` on `mailbox_unknown`).
    private enum Collected { case collected, failed, gone }

    /// One collect of the window, on [d] whatever the session: its relay client works on after a background stopped its
    /// collector. `gone` on `mailbox_unknown`. [last]: the window's last collect, whose refusal gives one more.
    private func windowCollect(_ d: VaultDevice, wait: TimeInterval, last: Bool, clock: WindowClock) async -> Collected {
        moveFlags.book.windowCollectSent = config.uptime()
        let own = clock.own, uptime = config.uptime
        defer { own.ended(at: uptime()) }
        do {
            try await d.collectOnce(
                timeout: wait + Self.collectSlack, wait: wait, attempts: 1, sleep: config.transferCollectSleep,
                sent: { own.sent(WindowSent(at: uptime(), wait: wait)) }, fresh: true
            )
            return .collected
        } catch let e as RelayError where e.code == RelayError.mailboxUnknown {
            return .gone
        } catch let e as RelayError where e.status >= 500 || e.status < 400 {
            // A 5xx, or an answer that could not be read: what the relay handed it may be leased, as for the collector.
            clock.cut(self, d, sent: own.out)
            return .failed
        } catch let e as RelayError where last && e.retryable {
            // The last collect refused (429, a stale signature): one more, after `retry_after`.
            clock.refused(self, retryAfter: TimeInterval(e.retryAfterSeconds))
            return .failed
        } catch is RelayError {
            // A relay's 4xx: nothing was taken up for this request.
            return .failed
        } catch is CancellationError {
            // The window itself ends.
            return .failed
        } catch {
            // No answer (a transport failure, a timeout): what the relay handed it may be leased, so the end moves out.
            clock.cut(self, d, sent: own.out)
            return .failed
        }
    }

    /// Whether a collector long-polls the mailbox now: [d]'s, or the device of a session opened since (the foreground).
    private func collectorRuns(_ d: VaultDevice) -> Bool { d.collecting || session?.device.collecting == true }

    /// The window's visibility timeout, clamped: the relay's as it advertises it now (asked within ``limitsBound``), else
    /// the one its last registration gave (kept with the device), else the default.
    private func windowVisibility(_ d: VaultDevice) async -> TimeInterval {
        let asked: TimeInterval? = await withTaskGroup(of: TimeInterval?.self) { group in
            group.addTask { (try? await d.relayLimits()).map { TimeInterval($0.visibilityTimeoutSeconds) } }
            group.addTask {
                try? await Task.sleep(for: Self.limitsBound)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        return min(max(asked ?? d.storedRelayVisibility ?? Self.defaultVisibility, 0), Self.maxVisibility)
    }

    func windowTimer(_ length: TimeInterval, _ ended: Flag) -> Task<Void, Never> {
        let windowSleep = config.transferWindowSleep
        return Task {
            try? await windowSleep(.seconds(length))
            ended.set()
        }
    }

    /// The `device.paired` or `device.pair.rejected` handled, if any: by [d], or by the device of a session opened since
    /// (its collector may have taken it).
    private func pairedOrRejected(_ d: VaultDevice) async -> WindowEnd {
        let found = await handled(by: d)
        if case .nothing = found, let other = session?.device, other !== d { return await handled(by: other) }
        return found
    }

    private func handled(by d: VaultDevice) async -> WindowEnd {
        do {
            return .paired(try await d.awaitTransfer(timeout: 0.05))
        } catch is PairingRejected {
            return .rejected
        } catch {
            return .nothing
        }
    }

    /// Waits for the device collector's request that is out now to end, its messages handled (at most the long-poll cap
    /// and the handling margin).
    private func collectorRound(_ d: VaultDevice) async {
        guard d.collecting, let out = d.collectRequestSince else { return }
        moveFlags.book.collectorRounds += 1
        let sleep = config.transferRetrySleep
        for _ in 0..<Int((Self.windowPoll + Self.handlingMargin) * 20) where d.collecting && d.collectRequestSince == out {
            try? await sleep(.milliseconds(50))
        }
    }

    /// Ends the window of collects before the drop at once (``collectBeforeDrop(_:)``): only for the process ending
    /// (``halt()``); nothing else cuts it.
    func cutSettleWindow() { moveFlags.book.settleWindow?.cancel() }

    /// Whether an abandon of the transfer waiting is refused (§11.14.10 rule 5): from the end of the vault's 10 minutes
    /// (``vaultApprovalWindow`` after the stored start), and while the window runs. An approval may just have reached the
    /// vault, and abandoning while a `device.paired` may be leased could leave a vault whose only app cannot open it.
    public var abandonClosed: Bool {
        if moveFlags.book.settling != nil { return true }
        guard let started = record.value.transferStartedMs else { return false }
        return config.now().timeIntervalSince1970 >= Double(started) / 1000 + Self.vaultApprovalWindow
    }

    /// The stored start of the transfer to this phone (its `hs.init`): the screen counts from it.
    public var transferStartedAt: Date? {
        record.value.transferStartedMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// The transfer waiting is waited for in the background (the screen that waited for it went, or a start found it):
    /// until its deadline and then its window, in the manager. How it ended without completing is told on the welcome
    /// screen (``TransferEndNotice/transferEnd``); the phase follows every outcome. A waiter cancelled (a new transfer, an
    /// abandon, the process ending) tells nothing.
    public func waitForTransferInBackground() {
        guard moveFlags.book.transferWaiter == nil, record.value.transferStartedMs != nil else { return }
        moveFlags.book.transferWaiter = Task { @MainActor [weak self] in
            var end: TransferEnd?
            do {
                _ = try await self?.awaitTransferIn()
            } catch let f as VaultFailure where f.code == Self.codeTransferDeadline {
                end = .timedOut
            } catch let f as VaultFailure where f.code == Self.codeTransferSessionEnded {
                end = .stopped
            } catch let f as VaultFailure where f.kind == .rejected {
                end = .declined
            } catch is PairingRejected {
                end = .declined
            } catch {}
            guard let self, !Task.isCancelled else { return }
            moveFlags.book.transferWaiter = nil
            if let end { transferEnd = end }
            try? await refresh()
        }
    }
}

extension VaultManager {
    /// The session the end of a window is settled through: [s], unless a background ended it and the foreground opened
    /// another, whose device is the one that writes the stored state now ([s]'s device is then halted). When only [s]'s
    /// device applied the pairing (it saved it), the current session is loaded again so that its device knows it: the newer
    /// device is halted first, and [s]'s after the reload; when the reload fails, [s] goes on as it is.
    func settlingSession(_ s: VaultSession) async -> VaultSession {
        guard let current = session, current.device !== s.device else { return s }
        let sessionEnds = moveFlags.book.sessionEnds
        guard s.device.deviceID != nil, current.device.deviceID == nil else {
            await s.device.halt()
            if moveFlags.book.transferSession?.device === s.device, moveFlags.book.sessionEnds == sessionEnds {
                moveFlags.book.transferSession = current
            }
            return current
        }
        // Neither device writes the stored state while the current session is loaded again from it: the newer one stops
        // for good (it would save its stale state back), and the window's, which saved the pairing, after the reload. The
        // reload loads a device of its own (not [s] taken back).
        await current.device.halt()
        stopCollecting()
        moveFlags.book.transferSession = nil
        guard let fresh = try? await openSession(), fresh.device !== s.device else {
            if moveFlags.book.sessionEnds == sessionEnds { moveFlags.book.transferSession = s }
            return s
        }
        await s.device.halt()
        // A wipe or a sign-out meanwhile ended the transfer's session: none is held for it any more.
        if moveFlags.book.sessionEnds == sessionEnds { moveFlags.book.transferSession = fresh }
        return fresh
    }

    /// The transfer's own session taken back by an opening (the foreground after a background) while the transfer is
    /// waited for: its device, stopped by the background, collects again. Nil when there is none to take back.
    func takeBackTransferSession() -> VaultSession? {
        guard !halted, session == nil, let held = moveFlags.book.transferSession, !held.device.ended,
              held.identity == record.value.activeIdentity,
              moveFlags.book.transferWaiter != nil || moveFlags.book.settling != nil || moveFlags.book.waitingIn > 0
        else { return nil }
        session = held
        memberVault.set(device: held.device)
        if !backgrounded { held.device.start() }
        observe(held)
        return held
    }
}
