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
    /// which would leave what it was handed leased to a dead request. The relay client's own retries of a failed attempt
    /// (5xx, 429) run inside the same bound: one that is still out when it ends is cancelled; only a relay that fails and
    /// then answers after more than a minute meets that (chosen; not in the spec).
    nonisolated static let collectSlack: TimeInterval = 70
    /// The bound of the registration that gives the relay's visibility timeout; past it, the default (chosen; not in the
    /// spec: a relay that answers `retry_after` must not hold the window).
    nonisolated static let limitsBound: Duration = .seconds(10)

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
        /// The transfer's session ended: `mailbox_unknown`, or the app signed out or wiped (the session went).
        case ended
        case nothing
    }

    /// The collects before the drop: collects of the mailbox for ``settleWindow(visibility:)``
    /// (``VaultManagerConfig/transferWindowSleep``), until a `device.paired{transfer}` comes (it is applied), a
    /// `device.pair.rejected` (at once) or the session ends (at once). Long polls sized from the time left, or `wait=0`
    /// collects while the device's own collector long-polls; none is ever cancelled while out (``collectSlack``). A collect
    /// that fails is tried again after a pause (``VaultManagerConfig/transferRetrySleep``). After the window, one `wait=0`
    /// collect, and a round of the collector that was out then is waited for, so that what it took is handled before the
    /// decision. The window is the manager's, not its caller's: a screen that goes away does not cut it; only the process
    /// ending does (``cutSettleWindow()``). Back in the foreground during it, a full window runs again (chosen; rule 5 says
    /// so of an app stopped during the window: a suspended app's collects were cut, and their leases may still run).
    func collectBeforeDrop(_ d: VaultDevice) async -> WindowEnd {
        let window = Task { @MainActor [self] in await collectWindow(d) }
        moveFlags.book.settleWindow = window
        defer { moveFlags.book.settleWindow = nil }
        return await window.value
    }

    private func collectWindow(_ d: VaultDevice) async -> WindowEnd {
        let length = await windowLength(d)
        var ended = Flag()
        var timer = windowTimer(length, ended)
        defer { timer.cancel() }
        var until = config.now().addingTimeInterval(length)
        var lifecycle = moveFlags.book.lifecycle
        var failures = 0
        while !Task.isCancelled {
            if moveFlags.book.lifecycle != lifecycle {
                lifecycle = moveFlags.book.lifecycle
                if !backgrounded {
                    timer.cancel()
                    ended = Flag()
                    timer = windowTimer(length, ended)
                    until = config.now().addingTimeInterval(length)
                }
            }
            // Signed out or wiped meanwhile: the session this window collects for is gone.
            if session?.device !== d { return .ended }
            let last = ended.value
            let left = until.timeIntervalSince(config.now()) - Self.handlingMargin
            let wait = last || d.collecting ? 0 : min(Self.windowPoll, max(left, 0)).rounded(.down)
            do {
                try await d.collectOnce(timeout: wait + Self.collectSlack, wait: wait, sleep: config.transferCollectSleep)
                failures = 0
            } catch let e as RelayError where e.code == RelayError.mailboxUnknown {
                return .ended
            } catch {
                failures += 1
            }
            if last { await collectorRound(d) }
            let found = await pairedOrRejected(d)
            if case .nothing = found {} else { return found }
            if last { return .nothing }
            // Between collects: a pause after a failure (1 s, doubled, at most 8 s), or while the collector long-polls.
            if failures > 0 || wait == 0 {
                try? await config.transferRetrySleep(.seconds(failures > 0 ? min(Double(1 << min(failures - 1, 3)), 8) : 1))
            }
        }
        return await pairedOrRejected(d)
    }

    /// The window's length, from the relay's advertised visibility timeout (its registration, bounded by ``limitsBound``).
    private func windowLength(_ d: VaultDevice) async -> TimeInterval {
        let visibility: TimeInterval? = await withTaskGroup(of: TimeInterval?.self) { group in
            group.addTask { (try? await d.relayLimits()).map { TimeInterval($0.visibilityTimeoutSeconds) } }
            group.addTask {
                try? await Task.sleep(for: Self.limitsBound)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        return Self.settleWindow(visibility: visibility)
    }

    private func windowTimer(_ length: TimeInterval, _ ended: Flag) -> Task<Void, Never> {
        let windowSleep = config.transferWindowSleep
        return Task {
            try? await windowSleep(.seconds(length))
            ended.set()
        }
    }

    /// The `device.paired` or `device.pair.rejected` the device has handled, if any.
    private func pairedOrRejected(_ d: VaultDevice) async -> WindowEnd {
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
    var abandonClosed: Bool {
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
