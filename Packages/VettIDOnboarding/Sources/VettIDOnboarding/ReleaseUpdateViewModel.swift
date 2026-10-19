import Foundation
import Observation
import VettIDData

/// The update screen's state ("Update now"). The PIN is the keypad's, never here. Mirrors vettid-android
/// `ReleaseUpdateUiState`.
public struct ReleaseUpdateState: Equatable, Sendable {
    public var loading = true
    public var offer: ReleaseUpdateOffer?
    /// The owner check is due or held (§3.6.5): it comes first; the root's gate shows it.
    public var checkDue = false
    /// What's new in the offered release; nil while it loads. Never gates the approval.
    public var notes: ReleaseNotes?

    public init(loading: Bool = true, offer: ReleaseUpdateOffer? = nil, checkDue: Bool = false, notes: ReleaseNotes? = nil) {
        self.loading = loading
        self.offer = offer
        self.checkDue = checkDue
        self.notes = notes
    }

    /// Whether "Approve and update" may be pressed with [pinTyped] digits on the keypad.
    public func submitAllowed(pinTyped: Int) -> Bool { offer != nil && !checkDue && pinTyped >= UnlockState.minPinLength }
}

/// The update screen (owner decision 2026-10-09): the release offered, its fingerprint and What's new, and "Approve and
/// update" with the vault PIN. The approval leaves this screen at once for the update's own screens at the root
/// (``ReleaseUpdateFlowViewModel``); the PIN is handed over and not kept. Mirrors vettid-android `ReleaseUpdateViewModel`.
@MainActor
@Observable
public final class ReleaseUpdateViewModel {
    public private(set) var state: ReleaseUpdateState

    @ObservationIgnored private let updates: any ReleaseUpdateRepository
    @ObservationIgnored private let releaseNotes: any ReleaseNotesRepository
    @ObservationIgnored private let followers = TaskBag()
    @ObservationIgnored private var notesTask: Task<Void, Never>?
    @ObservationIgnored private var notesFor: String?
    @ObservationIgnored private var refresh: Task<Void, Never>?

    public init(
        updates: any ReleaseUpdateRepository,
        ownerCheck: (any OwnerCheckRepository)? = nil,
        notes: any ReleaseNotesRepository,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.updates = updates
        releaseNotes = notes
        state = ReleaseUpdateState(loading: updates.offer == nil, offer: updates.offer)
        followers.add(follow(self, read: { $0.updates.offer }, apply: { $0.offerChanged($1) }))
        if let ownerCheck {
            followers.add(follow(
                ownerCheck, read: { $0.ownerCheck?.gated(now()) == true || $0.lockedByOwnerCheck },
                apply: { [weak self] _, due in self?.state.checkDue = due }
            ))
        }
        refresh = Task { [weak self, updates] in
            await updates.refreshOffer()
            self?.state.loading = false
        }
    }

    deinit {
        followers.cancelAll()
        notesTask?.cancel()
        refresh?.cancel()
    }

    /// The offer changed: What's new loads again for a new target (number and PCR0); each visit retries.
    private func offerChanged(_ o: ReleaseUpdateOffer?) {
        state.offer = o
        let key = o.map { "\($0.target.number)|\($0.target.pcr0)" }
        guard key != notesFor else { return }
        notesFor = key
        notesTask?.cancel()
        state.notes = nil
        guard let o else { return }
        let repo = releaseNotes
        notesTask = Task { [weak self] in
            let n = await repo.whatsNew(target: o.target, between: o.between)
            guard !Task.isCancelled, let self, self.notesFor == key else { return }
            self.state.notes = n
        }
    }

    /// "Approve and update": the member's explicit approval of the release shown, with the vault PIN from the keypad.
    /// False when it did not start (nothing offered, the check first, or too short a PIN).
    @discardableResult
    public func approve(pin: String) -> Bool {
        let digits = String(pin.filter { $0.isASCII && $0.isNumber }.prefix(UnlockState.maxPin))
        guard let offer = state.offer, state.submitAllowed(pinTyped: digits.count) else { return false }
        if updates.start(pin: digits, offer: offer) { return true }
        state.checkDue = updates.ownerCheckDue()
        return false
    }

    /// TEST ONLY: returns once the refresh and (unless [refreshOnly]) What's new have run.
    func settle(refreshOnly: Bool = false) async {
        await refresh?.value
        if refreshOnly { return }
        for _ in 0..<20 {
            await Task.yield()
            await notesTask?.value
        }
    }
}

/// The update's own screens' state (progress, outcome, the way back). The PIN is the keypad's, never here. Mirrors
/// vettid-android `ReleaseUpdateFlowUiState`.
public struct ReleaseUpdateFlowState: Equatable, Sendable {
    public var progress: UpdateProgress?
    /// The enclave's backoff, counted down here (§11.8).
    public var waitSeconds: Int64 = 0
    /// "Return to release N" asks first.
    public var abandonConfirm = false

    public init(progress: UpdateProgress? = nil) {
        self.progress = progress
    }

    public var pinAllowed: Bool { waitSeconds == 0 && progress?.waiting == true }

    public func retryAllowed(pinTyped: Int) -> Bool { pinAllowed && pinTyped >= UnlockState.minPinLength }
}

/// The update under way, shown by the root over every phase (``ReleaseUpdateRepository/progress``). Mirrors
/// vettid-android `ReleaseUpdateFlowViewModel`.
@MainActor
@Observable
public final class ReleaseUpdateFlowViewModel {
    public private(set) var state: ReleaseUpdateFlowState

    @ObservationIgnored private let updates: any ReleaseUpdateRepository
    @ObservationIgnored private let tick: @Sendable () async throws -> Void
    @ObservationIgnored private let followers = TaskBag()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var last: UpdateProgress?

    public init(
        updates: any ReleaseUpdateRepository,
        tick: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    ) {
        self.updates = updates
        self.tick = tick
        state = ReleaseUpdateFlowState(progress: updates.progress)
        followers.add(follow(self, read: { $0.updates.progress }, apply: { $0.progressChanged($1) }))
    }

    deinit {
        followers.cancelAll()
        ticker?.cancel()
    }

    private func progressChanged(_ p: UpdateProgress?) {
        state.progress = p
        // A new answer with a backoff (not the same one again): count it down.
        var before = last
        before?.starting = p?.starting ?? false
        if let p, p.waitSeconds > 0, before != p { startWait(p.waitSeconds) }
        last = p
    }

    /// "Try again" (or "Approve and update" after a wrong PIN) with the PIN from the keypad.
    @discardableResult
    public func retry(pin: String) -> Bool {
        guard state.retryAllowed(pinTyped: pin.count) else { return false }
        updates.retry(pin: pin)
        return true
    }

    public func askAbandon() {
        if state.progress?.canAbandon == true { state.abandonConfirm = true }
    }

    public func dismissAbandon() { state.abandonConfirm = false }

    /// "Return to release N", confirmed, with the PIN from the keypad.
    @discardableResult
    public func confirmAbandon(pin: String) -> Bool {
        state.abandonConfirm = false
        guard state.retryAllowed(pinTyped: pin.count), state.progress?.step == .newReleaseFailed else { return false }
        updates.abandon(pin: pin)
        return true
    }

    public func finish() {
        state.abandonConfirm = false
        updates.finish()
    }

    private func startWait(_ seconds: Int64) {
        ticker?.cancel()
        state.waitSeconds = seconds
        let tick = tick
        ticker = Task { [weak self] in
            while let s = self, s.state.waitSeconds > 0 {
                do {
                    try await tick()
                } catch {
                    return
                }
                guard let s = self else { return }
                s.state.waitSeconds = max(s.state.waitSeconds - 1, 0)
            }
        }
    }

    /// TEST ONLY: returns once the countdown has run out.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        await ticker?.value
    }
}
