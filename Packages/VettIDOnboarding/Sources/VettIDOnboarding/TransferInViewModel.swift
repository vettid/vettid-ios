import Foundation
import Observation
import VettIDData

/// The new phone's side of a direct transfer (VAULT-MESSAGING §6.7.1), as vettid-vault's `vaultctl pair`: scan the old
/// phone's QR (or paste its link), send the attested `hs.init`, show the SAS once the handshake checked out (or, without
/// the vault's `hs.resp` within 60 seconds, say that the code may have been used or this phone could not be verified, and
/// offer a new code, §6.7.1 step 2) and wait for the old phone's approval, which completes the transfer
/// (`device.paired{transfer: true}`), or its rejection (`device.pair.rejected`). Then the credential the vault kept is
/// fetched and confirmed. Mirrors vettid-android `TransferInViewModel`; the clock and the waits are injected (a virtual
/// clock in the tests).
@MainActor
@Observable
public final class TransferInViewModel: TransferInActions {
    /// The approval window: 10 minutes after `hs.init` (§6.7, 0.10.4).
    static let window: TimeInterval = 600

    public private(set) var state = TransferInState()

    @ObservationIgnored private let move: any MoveRepository
    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private var waiter: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init(
        move: any MoveRepository,
        vault: any VaultRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.move = move
        self.vault = vault
        self.now = now
        self.sleep = sleep
    }

    deinit {
        work.cancelAll()
        waiter?.cancel()
        ticker?.cancel()
    }

    public func scan() {
        state.step = .scan
        state.inputProblem = nil
        state.error = nil
    }

    public func paste() {
        state.step = .paste
        state.inputProblem = nil
        state.error = nil
    }

    @discardableResult
    public func back() -> Bool {
        switch state.step {
        case .scan, .paste:
            state.step = .intro
            state.inputProblem = nil
            return true
        case .connecting, .compare:
            cancel()
            return true
        default:
            return false
        }
    }

    public func scanned(_ text: String) {
        guard state.step == .scan, !state.busy else { return }
        start(text)
    }

    public func setInput(_ v: String) {
        state.input = v
        state.inputProblem = nil
    }

    public func submitInput() { start(state.input) }

    /// Checks the code locally first: nothing is fetched for a code of another kind or an expired one.
    private func start(_ text: String) {
        let problem: FailureKind? = switch InviteLinks.parseTransfer(text, now: now()) {
        case .ok: nil
        case .expired: .inviteExpired
        case .notATransfer, .invalid: .inviteInvalid
        }
        if let problem {
            state.inputProblem = problem
            return
        }
        let from = state.step
        state.step = .connecting
        state.busy = true
        state.inputProblem = nil
        state.error = nil
        state.sas = nil
        waiter?.cancel()
        // The task holds the model weakly and never across an await, so a dropped model can deinit (and cancel it); and
        // after every await it stops if it was cancelled: Swift cannot interrupt an await, and a repository that returns
        // normally after `cancel()` must not move the state.
        waiter = Task { @MainActor [weak self, move, vault, now, sleep] in
            let deadline = now().addingTimeInterval(Self.window)
            guard let sas = await Self.connect(Weak(self), move, sleep, text, from: from) else { return }
            await Self.awaitApproval(Weak(self), move, vault, sas: sas, deadline: deadline)
        }
    }

    /// The model, held weakly (a task's frame must not keep it alive across an await).
    private struct Weak {
        weak var model: TransferInViewModel?
        init(_ model: TransferInViewModel?) { self.model = model }
    }

    /// The SAS, or nil when the step ended (a failure, no `hs.resp` within 60 s, or cancelled; the state says which).
    private static func connect(
        _ w: Weak, _ move: any MoveRepository, _ sleep: @escaping @Sendable (Duration) async throws -> Void, _ text: String,
        from: TransferInStep
    ) async -> String? {
        let sas: String?
        do {
            sas = try await sasWithin(move, sleep, text)
        } catch {
            if !Task.isCancelled { w.model?.connectFailed(from, failure(of: error)) }
            return nil
        }
        guard !Task.isCancelled else { return nil }
        guard let sas else {
            // §6.7.1 step 2: stop waiting for hs.resp after 60 s; the handshake state is dropped.
            w.model?.state.step = .notAnswered
            w.model?.state.busy = false
            // Nothing to drop when it fails.
            try? await move.abandonTransferIn()
            return nil
        }
        return sas
    }

    /// Shows the SAS, then waits for the old phone's approval and takes the credential over.
    private static func awaitApproval(
        _ w: Weak, _ move: any MoveRepository, _ vault: any VaultRepository, sas: String, deadline: Date
    ) async {
        do {
            // Held only here, never across the await below.
            guard let vm = w.model else { return }
            vm.state.step = .compare
            vm.state.busy = false
            vm.state.sas = sas
            vm.state.deadline = deadline
            vm.startTicker(deadline)
        }
        let canUnlock: Bool
        do {
            canUnlock = try await move.awaitTransferIn()
        } catch {
            if !Task.isCancelled { w.model?.approvalFailed(failure(of: error)) }
            return
        }
        guard !Task.isCancelled, let vm = w.model else { return }
        vm.ticker?.cancel()
        vm.state.step = .done
        vm.state.sas = nil
        vm.state.canUnlockLater = canUnlock
        vm.state.phoneSecret = vault.usesPhoneSecret
    }

    /// A failure as a ``VaultFailure``: any other error is ``FailureKind/other``, so the screen never freezes in a step.
    private static func failure(of error: any Error) -> VaultFailure {
        (error as? VaultFailure) ?? VaultFailure(.other)
    }

    private func approvalFailed(_ e: VaultFailure) {
        ticker?.cancel()
        state.sas = nil
        switch e.kind {
        case .rejected: state.step = .rejected
        case .noResponse: state.step = .timedOut
        default:
            state.step = .intro
            state.error = e.kind
            state.errorCode = e.code
        }
    }

    /// The SAS the vault's `hs.resp` gave, or nil when none came within ``MoveCodes/hsRespWait`` (the late answer, if any,
    /// is cancelled and changes nothing). Relies on ``MoveRepository/transferIn(code:)`` honouring cancellation.
    private static func sasWithin(
        _ move: any MoveRepository, _ sleep: @escaping @Sendable (Duration) async throws -> Void, _ code: String
    ) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { () async throws -> String? in try await move.transferIn(code: code) }
            group.addTask { try await sleep(MoveCodes.hsRespWait); return nil }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    /// The transfer could not start: a bad code, no `hs.resp` within 60 s (§6.7.1 step 2), or another failure.
    private func connectFailed(_ from: TransferInStep, _ e: VaultFailure) {
        state.busy = false
        if e.kind == .inviteInvalid || e.kind == .inviteExpired {
            state.step = from
            state.inputProblem = e.kind
        } else if e.code == MoveCodes.hsUnanswered {
            state.step = .notAnswered
        } else {
            state.step = from
            state.error = e.kind
            state.errorCode = e.code
        }
    }

    private func startTicker(_ deadline: Date) {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self, sleep] in
            // The model is held only inside `tickOnce`, never across the sleep.
            while !Task.isCancelled, self?.tickOnce(deadline) == true {
                do {
                    try await sleep(.seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    /// Shows the seconds left; false when the window is over.
    private func tickOnce(_ deadline: Date) -> Bool {
        let left = max(Int64(deadline.timeIntervalSince(now()).rounded(.down)), 0)
        state.secondsLeft = left
        return left > 0
    }

    /// Leaves a transfer in progress: nothing was approved, so nothing changes; the handshake state is dropped.
    public func cancel() {
        waiter?.cancel()
        ticker?.cancel()
        state.step = .intro
        state.busy = false
        state.sas = nil
        state.deadline = nil
        work.launch { [weak self] in await self?.abandon() }
    }

    private func abandon() async {
        // Nothing to drop when it fails.
        try? await move.abandonTransferIn()
    }

    public func again() {
        state = TransferInState(step: .scan)
    }

    public func finish() {
        work.launch { [vault] in try? await vault.finishSetup() }
    }

    /// TEST ONLY: returns once what the model started has run as far as it can without a wait of the repository's or the
    /// clock's.
    func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }
}
