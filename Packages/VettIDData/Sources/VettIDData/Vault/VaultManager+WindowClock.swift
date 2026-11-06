import Foundation
import VettIDVault

// The clock of a transfer's settlement window (VAULT-MESSAGING 0.85.2 §11.14.10 rule 5): its end, and what may have been
// leased while it ran (``VaultManager/collectBeforeDrop(_:)``).
extension VaultManager {
    /// A request of the window or a collector, sent at `at` (uptime) with a long poll of `wait`: the relay may answer it,
    /// and the lease of what it hands out start, as late as `at + wait` (chosen; the shared rule with Android #307, the
    /// erratum to follow).
    struct WindowSent: Sendable {
        let at: TimeInterval
        let wait: TimeInterval
        var answered: TimeInterval { at + wait }

        init(at: TimeInterval, wait: TimeInterval) {
            (self.at, self.wait) = (at, wait)
        }

        init(_ s: VaultDevice.CollectSent) { self.init(at: s.at, wait: s.wait) }
    }

    /// The window's own collect: the one out now (from the moment it goes out, each attempt), and the last one. Set off
    /// the main actor by the transport, read by the clock.
    final class OwnSends: @unchecked Sendable {
        private let lock = NSLock()
        private var now: WindowSent?
        private var latest: WindowSent?
        private var latestEnd: TimeInterval?
        var out: WindowSent? { lock.withLock { now } }
        var last: WindowSent? { lock.withLock { latest } }
        /// When the last request ended (uptime); nil while it is out.
        var lastEnded: TimeInterval? { lock.withLock { latestEnd } }
        func sent(_ s: WindowSent) { lock.withLock { (now, latest, latestEnd) = (s, s, nil) } }
        func ended(at up: TimeInterval) { lock.withLock { if now != nil { latestEnd = up }; now = nil } }
    }

    /// The window's timer and end, counted on the monotonic uptime (it runs through a sleep of the phone), and what it saw
    /// of cuts, freezes and the background. A collect cut (the collector's round failed or was stopped, or a collect of the
    /// window lost its answer), a freeze or a background may leave a message leased for a visibility timeout V. For a cut
    /// whose request went at s (a long poll's send + its `wait`: the relay may answer it that late), the end moves to
    /// min(max(end, the end of its lease, below), cap); for a freeze, a background or a cut of unknown s, to min(max(end, now + V), cap);
    /// the cap is ``maxEndPastFirst(visibility:)`` past the first end, which never moves. A cut whose request went at or
    /// before a freeze began is the freeze's: no cut of its own. While the app is in the background nothing is decided;
    /// back in the foreground the end moves out so.
    ///
    /// A cut's lease is taken to run to max(s + wait, when the cut was noticed) + 15 s + V: the relay may have been handed
    /// the request late, and have leased what it handed it up to the notice; the margin is added to either.
    ///
    /// A window that is over makes one last `wait=0` collect, then drops. After a freeze while a request was out (the
    /// wake before the cap or after it), or a cut past the cap or whose lease end is past it, that collect goes out no
    /// sooner than that lease end (for a freeze, s + V + 15 s, ``holdMargin``; s the latest request sent at or before the
    /// freeze). A cut, a freeze (each counts as a note) while that last collect is out, or during its hold, and a refusal
    /// of it (429, a stale signature), give one more last collect (at most one per window, so held last collects cannot
    /// repeat), no sooner than the lease end of the cut, of a freeze noted meanwhile (the wake + the wait of what was sent
    /// before it + V + 15 s), the hold raised meanwhile, or the refusal's `retry_after` (at most V). Before the one more, a
    /// bare background gives nothing, and the same notes during the looks give the one more too, if it is unused.
    ///
    /// **The hold budget** (the shared rule with Android #307): the first hold past the cap is free, then ONE extra in all,
    /// the one more last collect (with its own hold); no other hold past the cap is taken after it, apart from the first
    /// one if none was raised before. A hold that ends at or below the cap is free (the cap bounds it). After the
    /// one more, a cut or a freeze still moves the end out within the cap, and the window collects on to it; a hold raised
    /// during the one more's collect is waited for once more, with a `wait=0` look before the drop
    /// (``holdAfterExtra(_:)``), if the budget allows it. A background during the one more's collect moves the end out
    /// too if the app is back in the foreground when that collect is answered; if it is still in the background then, the
    /// window goes to its look and the drop (nothing is decided in the background, and the look collects after it).
    ///
    /// After the last collect, in the foreground, the window takes a last look
    /// (``VaultManager/lastLook(_:clock:sessionEnds:)``: a `wait=0` collect after a background); a cut or a refusal of the
    /// look's collect, while the one more is still unused, gives it (no sooner than that collect's send + V + 15 s), and
    /// the drop follows that one's look. A freeze leases whatever was sent before it from the wake + that request's `wait`
    /// (the relay may be handed it only then). So the drop comes at most cap + 2 × V + 648 s of foreground time (a
    /// collect out at the end, two holds past the cap, the last collects past the cap (the first, the one more, and the
    /// look after the hold waited for after it; those that a note after the one more gives end by the cap), the looks,
    /// the collector's round after each last collect, the pauses); time in the background or frozen comes on top (chosen; the shared rule with Android
    /// #307, the erratum to follow).
    @MainActor
    final class WindowClock {
        let length: TimeInterval
        let visibility: TimeInterval
        private var ended = Flag()
        private var timer: Task<Void, Never>?
        private var heartbeat: Task<Void, Never>?
        private(set) var until: TimeInterval = 0
        private var cap: TimeInterval = 0
        /// The window's own collects (``OwnSends``).
        let own = OwnSends()
        /// The cuts and freezes noted so far, and as many as there were when the last collect went out; how many last
        /// collects went; a refusal of the last one, and the time it asks to wait to.
        private var notes = 0
        private var notesAtFinal: Int?
        private var finalRedone = false
        /// Whether a hold past the cap was raised (the first is free), and the end of the latest hold waited for.
        private var pastCapRaised = false
        private var waitedTo: TimeInterval = 0
        /// The end of the window when the last collect went.
        private var untilAtFinal: TimeInterval = 0
        /// Whether the wait after the one more last collect was made (``holdAfterExtra(_:)``, once).
        private var heldAfterExtra = false
        /// The latest end of a freeze's lease noted.
        private var freezeHoldAt: TimeInterval?
        private var finalsGone = 0
        private var refusedUntil: TimeInterval?
        /// The backgrounds counted when the last collect went.
        private var backgroundsAtFinal = 0
        /// The heartbeat's last tick, the latest send + wait of the requests out then, and the tick before the last freeze.
        private var lastTick: TimeInterval = 0
        private var lastOuts: [WindowSent] = []
        private var freezeBegan: TimeInterval?
        /// Whether a collector's stream was open at the last tick: one open through a freeze may have pushed, and leased,
        /// up to the wake.
        private var streamWasOpen = false
        /// Set by ``stop()``: no device is followed any more.
        private var stopped = false
        /// Every collector seen during the window, and the cuts seen of each: a session's device whose session went (a
        /// background) is still followed.
        private var collectors: [VaultDevice] = []
        private var cuts: [ObjectIdentifier: Int] = [:]
        /// A cut, a freeze or a background not yet followed by the end moving out: whether one moves it to now + V, and the
        /// latest send + wait of the requests cut.
        private var pending: Bool
        private var widen: Bool
        private var pendingSent: TimeInterval?
        /// The latest start of a cut's lease noted: max(send + wait, when the cut was noticed) + 15 s.
        private var lastCutLease: TimeInterval?
        /// The earliest uptime of the last collect, after a freeze while a request was out, or a cut past the cap or whose
        /// lease (max(s + wait, notice) + 15 s + V) ends past it.
        private(set) var finalNotBefore: TimeInterval?
        private var backgrounds: Int

        init(visibility: TimeInterval, backgrounds: Int, background: Bool) {
            length = VaultManager.settleWindow(visibility: visibility)
            self.visibility = visibility
            self.backgrounds = backgrounds
            pending = background
            widen = background
        }

        /// The window is over, and may be decided.
        var over: Bool { ended.value && !pending }

        func start(_ m: VaultManager, _ d: VaultDevice) {
            let up = m.config.uptime()
            until = up + length
            cap = until + VaultManager.maxEndPastFirst(visibility: visibility)
            lastTick = up
            for x in Self.devices(m, d) { watch(x, from: x.collectorCuts.count) }
            arm(m, length)
            let sleep = m.config.transferHeartbeatSleep
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await sleep(.seconds(1))
                    // A heartbeat stopped during its sleep looks no more (it would follow, and mark, devices again).
                    guard !Task.isCancelled else { return }
                    self?.follow(m, d)
                    m.moveFlags.book.windowBeats += 1
                }
            }
        }

        func stop() {
            stopped = true
            timer?.cancel()
            heartbeat?.cancel()
            for x in collectors { x.setCollectsFresh(false) }
        }

        /// [d], and the device of a session opened since (its collector may take the pairing too).
        static func devices(_ m: VaultManager, _ d: VaultDevice) -> [VaultDevice] {
            if let other = m.session?.device, other !== d { return [d, other] }
            return [d]
        }

        /// A device first seen now counts the cuts from now on, and its latest cut too if that cut was noticed at or after
        /// the last tick (a cut in the moment before it was seen); those before are not the window's.
        private func watchNew(_ x: VaultDevice) {
            let c = x.collectorCuts
            let latest = x.collectorCutNoticed.map { $0 >= lastTick } ?? false
            watch(x, from: c.count > 0 && latest ? c.count - 1 : c.count)
        }

        private func watch(_ x: VaultDevice, from count: Int) {
            guard !stopped, cuts[ObjectIdentifier(x)] == nil else { return }
            // Its long polls go on connections of their own while the window follows it.
            x.setCollectsFresh(true)
            collectors.append(x)
            cuts[ObjectIdentifier(x)] = count
        }

        private func arm(_ m: VaultManager, _ seconds: TimeInterval) {
            timer?.cancel()
            ended = Flag()
            timer = seconds > 0 ? m.windowTimer(seconds, ended) : nil
            if seconds <= 0 { ended.set() }
        }

        /// A request of the window (sent as [sent]; nil: it never went out) was cut: its answer, and what the relay handed
        /// it, may be lost.
        func cut(_ m: VaultManager, _ d: VaultDevice, sent: WindowSent?) {
            noteCut(sent, noticed: m.config.uptime())
            follow(m, d)
        }

        /// The last collect was refused (429, a stale signature): one more goes, after [retryAfter] (at most V), on a
        /// request signed anew (chosen; the shared rule with Android #307, the erratum to follow).
        func refused(_ m: VaultManager, retryAfter: TimeInterval) {
            refusedUntil = m.config.uptime() + min(max(retryAfter, 0), visibility)
        }

        /// A cut of a request sent as [sent]. One sent at or before a freeze began is the freeze's: it holds the last
        /// collect for its lease, but it is no cut of its own (chosen; the shared rule with Android #307, the erratum to
        /// follow).
        private func noteCut(_ sent: WindowSent?, noticed: TimeInterval) {
            if let sent, let began = freezeBegan, sent.at <= began + 1 {
                // Its lease may start as late as the cut is noticed, as for any cut; and it counts as a note, so that a
                // hold it raises while the last collect is out gives the one more.
                notes += 1
                holdFinal(max(sent.answered, noticed))
                return
            }
            notes += 1
            pending = true
            guard let sent else {
                widen = true
                return
            }
            // The relay may have leased what it handed the request as late as the failure is noticed (a late arrival).
            let lease = max(sent.answered, noticed) + VaultManager.holdMargin
            lastCutLease = max(lastCutLease ?? lease, lease)
            pendingSent = max(pendingSent ?? lease, lease)
        }

        /// A freeze that began after the tick at [began]; [sent]: the latest send + wait of the requests in flight then.
        private func noteFreeze(began: TimeInterval, sent: TimeInterval?) {
            notes += 1
            (pending, widen, freezeBegan) = (true, true, began)
            // While a request was out: the last collect waits for its lease, whether the wake came before the cap or after.
            if let sent { holdFinal(sent) }
        }

        /// A freeze's hold (or a cut attributed to a freeze): the last collect waits until [sent] + V + 15 s.
        private func holdFinal(_ sent: TimeInterval) {
            let at = sent + visibility + VaultManager.holdMargin
            // Kept whatever follows: the one more last collect, if it is given because of this freeze, waits for it too.
            freezeHoldAt = max(freezeHoldAt ?? 0, at)
            raiseHold(to: at)
        }

        /// A cut's lease hold: the last collect waits until the end of the lease ([lease] + V).
        private func holdForLease(_ lease: TimeInterval) {
            raiseHold(to: lease + visibility)
        }

        /// Raises the hold of the next last collect. A hold only moves out. Before the one more is given, any hold is
        /// taken (what is raised during a wait gives the one more). The first hold past the cap is free; after the one more
        /// (the extra, with its own hold), no other is taken past the cap, and a hold at or below the cap is free (the cap
        /// bounds it); chosen; the shared rule with Android #307, the erratum to follow.
        private func raiseHold(to at: TimeInterval) {
            if at > cap {
                if finalRedone, pastCapRaised { return }
                pastCapRaised = true
            }
            finalNotBefore = max(finalNotBefore ?? 0, at)
        }

        /// The hold of the one more last collect being given now for a cut: the end of the cut's lease, and of any
        /// freeze's lease noted since. It is the extra's own hold: set here, not through ``raiseHold(to:)``, so it does
        /// not use the first hold past the cap (one more may still be raised after it: the two holds past the cap of the
        /// bound).
        private func holdForRedo(_ lease: TimeInterval) {
            finalNotBefore = max(finalNotBefore ?? 0, lease + visibility, freezeHoldAt ?? 0)
        }

        /// The start of the lease of what the cut request [sent] may have been handed: no earlier than the cut was noticed.
        private func leaseOfCut(_ sent: TimeInterval) -> TimeInterval {
            max(sent + VaultManager.holdMargin, lastCutLease ?? 0)
        }

        /// Notes the cuts, a freeze (a gap of the uptime since the heartbeat's last tick, seen here too in case this runs
        /// first on a resume) and a background, and moves the end out after one, in the foreground.
        func follow(_ m: VaultManager, _ d: VaultDevice) {
            let up = m.config.uptime()
            // A device first seen now counts the cuts from now (those before are not the window's).
            for x in Self.devices(m, d) { watchNew(x) }
            if up - lastTick > VaultManager.freezeGap {
                // The requests in flight when it began: those out at the last tick, and the latest sent before the next tick
                // was due, kept after it ended (one that failed on the wake, before this ran), not one sent since the wake.
                // Only a request still out when the freeze began (or ended after the last tick) holds the last collect.
                var sends: [WindowSent] = []
                if let s = own.last, sentAtFreeze(s, now: up, still: own.out != nil, ended: own.lastEnded) { sends.append(s) }
                for x in collectors {
                    if let s = x.lastCollectorSent.map(WindowSent.init),
                       sentAtFreeze(s, now: up, still: x.collectRequestSent != nil, ended: x.lastCollectorEnded) { sends.append(s) }
                }
                // Whatever was sent before the freeze may have reached the relay only on the wake, which parks it for its
                // `wait`: its lease starts at the wake + that wait (0 for a stream or a `wait=0` collect).
                let starts = (lastOuts + sends).map { up + $0.wait } + (streamWasOpen ? [up] : [])
                noteFreeze(began: lastTick, sent: starts.max())
            }
            lastTick = up
            for x in collectors {
                let c = x.collectorCuts
                if c.count > cuts[ObjectIdentifier(x), default: 0] {
                    noteCut(c.sent.map(WindowSent.init), noticed: up)
                }
                cuts[ObjectIdentifier(x)] = c.count
            }
            if m.backgrounded || m.moveFlags.book.backgrounds != backgrounds {
                (pending, widen) = (true, true)
                backgrounds = m.moveFlags.book.backgrounds
            }
            lastOuts = outNow()
            streamWasOpen = collectors.contains { $0.streamOpen }
            guard pending, !m.backgrounded else { return }
            pending = false
            extend(m, now: up)
        }

        /// Whether the request [s] was out when the freeze began (the last tick): sent by then (up to a tick after it, or
        /// longer ago than the gap that counts as a freeze at [now]: sent after a late tick, before the freeze), and not
        /// ended before it.
        private func sentAtFreeze(_ s: WindowSent, now: TimeInterval, still: Bool, ended: TimeInterval?) -> Bool {
            (s.at <= lastTick + 1 || s.at <= now - VaultManager.freezeGap) && (still || ended.map { $0 >= lastTick } ?? true)
        }

        /// The requests out now: the window's own and the collectors'.
        private func outNow() -> [WindowSent] {
            ([own.out] + collectors.map { $0.collectRequestSent.map(WindowSent.init) }).compactMap { $0 }
        }

        private func extend(_ m: VaultManager, now: TimeInterval) {
            defer { (pendingSent, widen) = (nil, false) }
            var end = until
            if widen { end = max(end, now + visibility) }
            if let lease = pendingSent {
                // To the end of the cut request's lease, estimated (from the later of its answer's latest time + 15 s and
                // when the cut was noticed); one the cap cannot cover, the cut noticed before the cap or after, holds
                // the last collect (chosen; the shared rule with Android #307, the erratum to follow).
                end = max(end, lease + visibility)
                if now >= cap || lease + visibility > cap { holdForLease(lease) }
            }
            end = min(end, cap)
            guard end > until else { return }
            until = end
            arm(m, end - now)
        }

        /// Before the last collect (the window over), after a freeze while a request was out, or a cut past the cap or whose
        /// lease ends past it: until the end of that lease (a cut's: max(s + wait, notice) + 15 s + V; a freeze's: the
        /// wake + the wait of the request in flight then + V + 15 s). A hold at or below the cap
        /// is waited for each time it moves (bounded by the cap); a hold past it is waited for as the budget allows
        /// (``raiseHold(to:)``), so that cuts cannot chain it (chosen; the shared rule with Android #307, the erratum to
        /// follow). A cut or a freeze during the wait counts as one while the last collect is out.
        func waitForFinalCollect(_ m: VaultManager) async {
            guard over else { return }
            notesAtFinal = notes
            refusedUntil = nil
            untilAtFinal = until
            await waitForHold(m)
            finalsGone += 1
            backgroundsAtFinal = m.moveFlags.book.backgrounds
            m.moveFlags.book.finalCollects += 1
        }

        /// Waits for the hold, and for what moves it at or below the cap meanwhile.
        private func waitForHold(_ m: VaultManager) async {
            var first = true
            // Before the one more, a hold raised during the wait is waited for while it is at or below the cap (past it, the
            // one more takes it); after it, every hold taken is (``raiseHold(to:)`` admits one past the cap at most).
            while let at = finalNotBefore, first || (at > waitedTo && (at <= cap || finalRedone)) {
                first = false
                waitedTo = at
                if at > m.config.uptime() { try? await m.config.transferWindowSleep(.seconds(at - m.config.uptime())) }
            }
        }

        /// After the one more last collect, when the window would drop: whether a hold was raised since the last wait
        /// (by a cut or a freeze during that collect, within the budget) and has now been waited for, once per window;
        /// the caller makes a `wait=0` look then, before the drop.
        func holdAfterExtra(_ m: VaultManager) async -> Bool {
            guard finalRedone, finalsGone >= 2, !heldAfterExtra, let at = finalNotBefore, at > waitedTo else { return false }
            heldAfterExtra = true
            await waitForHold(m)
            return true
        }

        /// Whether the app went to the background since the last collect went (or is there now).
        func backgroundSinceFinal(_ m: VaultManager) -> Bool {
            m.backgrounded || m.moveFlags.book.backgrounds != backgroundsAtFinal
        }

        /// After a collect of the last look: whether a cut (a lost reply, a 5xx, an unreadable answer, or the window stopped),
        /// a freeze, or a refusal (429, a stale signature) came since the last collect went, while the one more last
        /// collect is unused: then that one is given, no sooner than the end of the lease of the cut or the freeze, or the
        /// refusal's `retry_after` (at most V).
        func redoneAfterLook(_ m: VaultManager, _ d: VaultDevice) -> Bool {
            follow(m, d)
            let noted = notesAtFinal.map { notes != $0 } ?? false
            guard !finalRedone, noted || refusedUntil != nil else { return false }
            if noted { holdForRedo(own.last.map { leaseOfCut($0.answered) } ?? 0) }
            if let r = refusedUntil { finalNotBefore = max(finalNotBefore ?? 0, r) }
            finalRedone = true
            return true
        }

        /// After the last collect: whether the window drops now. Not while a cut or a freeze moved the end out first; and a
        /// cut, a freeze or a background while that collect was out, or a refusal of it, gives one more last collect, once.
        /// After that one, the window drops (``VaultManager/lastLook(_:clock:sessionEnds:)``: in the foreground, after a last look).
        func dropsAfterFinalCollect(_ m: VaultManager, _ d: VaultDevice) -> Bool {
            follow(m, d)
            // After the one more, a cut or a freeze still moves the end out (within the cap): collects go on to it, and a
            // last collect follows it.
            if finalRedone, finalsGone >= 2 { return until <= untilAtFinal }
            let cutDuring = notesAtFinal.map { notes != $0 } ?? false
            if cutDuring || refusedUntil != nil, !finalRedone {
                if cutDuring { holdForRedo(own.last.map { leaseOfCut($0.answered) } ?? 0) }
                if let r = refusedUntil { finalNotBefore = max(finalNotBefore ?? 0, r) }
                finalRedone = true
                return false
            }
            return over
        }
    }

    /// While the app is in the background, a kept-alive window collects about every 15 s (``backgroundCollectPause``).
    func backgroundPause() async {
        moveFlags.book.windowPauseSeconds = Self.backgroundCollectPause
        try? await config.transferBackgroundSleep(.seconds(Self.backgroundCollectPause))
    }
}
