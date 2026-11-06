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
        var out: WindowSent? { lock.withLock { now } }
        var last: WindowSent? { lock.withLock { latest } }
        func sent(_ s: WindowSent) { lock.withLock { (now, latest) = (s, s) } }
        func ended() { lock.withLock { now = nil } }
    }

    /// The window's timer and end, counted on the monotonic uptime (it runs through a sleep of the phone), and what it saw
    /// of cuts, freezes and the background. A collect cut (the collector's round failed or was stopped, or a collect of the
    /// window lost its answer), a freeze or a background may leave a message leased for a visibility timeout V. For a cut
    /// whose request went at s (a long poll's send + its `wait`: the relay may answer it that late), the end moves to
    /// min(max(end, s + V + 15 s), cap); for a freeze, a background or a cut of unknown s, to min(max(end, now + V), cap);
    /// the cap is ``maxEndPastFirst(visibility:)`` past the first end, which never moves. A cut whose request went at or
    /// before a freeze began is the freeze's: no cut of its own. While the app is in the background nothing is decided;
    /// back in the foreground the end moves out so.
    ///
    /// A window that is over makes one last `wait=0` collect, then drops. After a freeze while a request was out (the
    /// wake before the cap or after it), or a cut past the cap or whose s + V is past it, that collect goes out no sooner
    /// than s + V + 15 s (``holdMargin``), s being the latest request sent at or before the freeze or cut. A cut, a
    /// freeze or a background while that last collect is out, or during its hold, and a refusal of it (429, a stale
    /// signature), give one more last collect (at most one per window), no sooner than its own s + V + 15 s, the hold a
    /// cut raised meanwhile, or the refusal's `retry_after` (at most V); then the drop, in the foreground, whatever else
    /// comes. So the drop comes at most 25 s + 3 × ``collectSlack`` + 2 × 30 s + 2 × (V + 40 s) of foreground time past the
    /// cap (a collect out at the end, two holds, two last collects and the collector's round after each); time in the
    /// background or frozen comes on top (chosen; the shared rule with Android #307, the erratum to follow).
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
        private var finalsGone = 0
        private var refusedUntil: TimeInterval?
        /// The backgrounds counted when the last collect went.
        private var backgroundsAtFinal = 0
        /// The heartbeat's last tick, the latest send + wait of the requests out then, and the tick before the last freeze.
        private var lastTick: TimeInterval = 0
        private var lastOut: TimeInterval?
        private var freezeBegan: TimeInterval?
        /// Every collector seen during the window, and the cuts seen of each: a session's device whose session went (a
        /// background) is still followed.
        private var collectors: [VaultDevice] = []
        private var cuts: [ObjectIdentifier: Int] = [:]
        /// A cut, a freeze or a background not yet followed by the end moving out: whether one moves it to now + V, and the
        /// latest send + wait of the requests cut.
        private var pending: Bool
        private var widen: Bool
        private var pendingSent: TimeInterval?
        /// The earliest uptime of the last collect, after a freeze while a request was out, or a cut past the cap or whose
        /// s + wait + V is past it.
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
                    self?.follow(m, d)
                    m.moveFlags.book.windowBeats += 1
                }
            }
        }

        func stop() {
            timer?.cancel()
            heartbeat?.cancel()
            for x in collectors { x.setCollectsFresh(false) }
        }

        /// [d], and the device of a session opened since (its collector may take the pairing too).
        static func devices(_ m: VaultManager, _ d: VaultDevice) -> [VaultDevice] {
            if let other = m.session?.device, other !== d { return [d, other] }
            return [d]
        }

        private func watch(_ x: VaultDevice, from count: Int) {
            guard cuts[ObjectIdentifier(x)] == nil else { return }
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
            noteCut(sent)
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
        private func noteCut(_ sent: WindowSent?) {
            if let sent, let began = freezeBegan, sent.at <= began + 1 {
                holdFinal(sent.answered)
                return
            }
            notes += 1
            pending = true
            guard let sent else {
                widen = true
                return
            }
            pendingSent = max(pendingSent ?? sent.answered, sent.answered)
        }

        /// A freeze that began after the tick at [began]; [sent]: the latest send + wait of the requests in flight then.
        private func noteFreeze(began: TimeInterval, sent: TimeInterval?) {
            notes += 1
            (pending, widen, freezeBegan) = (true, true, began)
            // While a request was out: the last collect waits for its lease, whether the wake came before the cap or after.
            if let sent { holdFinal(sent) }
        }

        private func holdFinal(_ sent: TimeInterval) {
            // Once the one more last collect is given, nothing holds it further (chosen; the shared rule with Android
            // #307, the erratum to follow).
            guard !finalRedone else { return }
            finalNotBefore = max(finalNotBefore ?? 0, sent + visibility + VaultManager.holdMargin)
        }

        /// Notes the cuts, a freeze (a gap of the uptime since the heartbeat's last tick, seen here too in case this runs
        /// first on a resume) and a background, and moves the end out after one, in the foreground.
        func follow(_ m: VaultManager, _ d: VaultDevice) {
            let up = m.config.uptime()
            for x in Self.devices(m, d) { watch(x, from: 0) }
            if up - lastTick > VaultManager.freezeGap {
                // The requests in flight when it began: those out at the last tick, and the latest sent before the next tick
                // was due, kept after it ended (one that failed on the wake, before this ran), not one sent since the wake.
                let sends = ([own.last] + collectors.map { $0.lastCollectorSent.map(WindowSent.init) }).compactMap { $0 }
                let then = sends.filter { $0.at <= lastTick + 1 }.map(\.answered)
                noteFreeze(began: lastTick, sent: ([lastOut] + then).compactMap { $0 }.max())
            }
            lastTick = up
            for x in collectors {
                let c = x.collectorCuts
                if c.count > cuts[ObjectIdentifier(x), default: 0] {
                    noteCut(c.sent.map(WindowSent.init))
                }
                cuts[ObjectIdentifier(x)] = c.count
            }
            if m.backgrounded || m.moveFlags.book.backgrounds != backgrounds {
                (pending, widen) = (true, true)
                backgrounds = m.moveFlags.book.backgrounds
            }
            lastOut = outNow().map(\.answered).max()
            guard pending, !m.backgrounded else { return }
            pending = false
            extend(m, now: up)
        }

        /// The requests out now: the window's own and the collectors'.
        private func outNow() -> [WindowSent] {
            ([own.out] + collectors.map { $0.collectRequestSent.map(WindowSent.init) }).compactMap { $0 }
        }

        private func extend(_ m: VaultManager, now: TimeInterval) {
            defer { (pendingSent, widen) = (nil, false) }
            // Once the one more last collect is given, nothing moves the end or holds it further: back in the foreground,
            // the window decides (chosen; the shared rule with Android #307, the erratum to follow).
            guard !finalRedone else { return }
            var end = until
            if widen { end = max(end, now + visibility) }
            if let s = pendingSent {
                // To the cut request's lease, estimated; one the cap cannot cover (s + V past it), the cut noticed before
                // the cap or after, holds the last collect (chosen; the shared rule with Android #307, the erratum to
                // follow).
                end = max(end, s + visibility + VaultManager.holdMargin)
                if now >= cap || s + visibility > cap { holdFinal(s) }
            }
            end = min(end, cap)
            guard end > until else { return }
            until = end
            arm(m, end - now)
        }

        /// Before the last collect (the window over), after a freeze while a request was out, or a cut past the cap or whose
        /// s + wait + V is past it: until s + wait + V + 15 s of the request in flight then. A cut or a freeze during the
        /// hold counts as one while the last collect is out (the one more last collect waits for the hold it raised); the
        /// hold is read once, not waited on again, so that cuts cannot chain it (chosen; the shared rule with Android #307,
        /// the erratum to follow).
        func waitForFinalCollect(_ m: VaultManager) async {
            guard over else { return }
            notesAtFinal = notes
            refusedUntil = nil
            if let at = finalNotBefore, at > m.config.uptime() {
                try? await m.config.transferWindowSleep(.seconds(at - m.config.uptime()))
            }
            finalsGone += 1
            backgroundsAtFinal = m.moveFlags.book.backgrounds
            m.moveFlags.book.finalCollects += 1
        }

        /// Whether the app went to the background since the last collect went (or is there now).
        func backgroundSinceFinal(_ m: VaultManager) -> Bool {
            m.backgrounded || m.moveFlags.book.backgrounds != backgroundsAtFinal
        }

        /// After the last collect: whether the window drops now. Not while a cut or a freeze moved the end out first; and a
        /// cut, a freeze or a background while that collect was out, or a refusal of it, gives one more last collect, once.
        /// After that one, the window drops (``VaultManager/lastLook(_:clock:)``: in the foreground, after a last look).
        func dropsAfterFinalCollect(_ m: VaultManager, _ d: VaultDevice) -> Bool {
            follow(m, d)
            if finalRedone, finalsGone >= 2 { return true }
            let cutDuring = notesAtFinal.map { notes != $0 } ?? false
            if cutDuring || refusedUntil != nil, !finalRedone {
                if cutDuring, let s = own.last?.answered { holdFinal(s) }
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
        try? await config.transferRetrySleep(.seconds(Self.backgroundCollectPause))
    }
}
