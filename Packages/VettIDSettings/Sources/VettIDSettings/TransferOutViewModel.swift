import Foundation
import Observation
import VettIDData

/// The steps of a direct transfer on the old phone (VAULT-MESSAGING §6.7.1). Mirrors vettid-android `TransferOutStep`.
public enum TransferOutStep: Equatable, Sendable {
    case intro
    /// The QR (pairing kind `p`, TTL 10 minutes); waiting for `device.transfer.pending`.
    case showing
    /// The new phone's handshake checked out: compare the SAS.
    case compare
    /// The new phone's VettID has another signer than the one the vault is bound to (`signer_changed`, VAULT-MESSAGING
    /// 0.27.0 §11.7.1): the member confirms the change, named in words, before the PIN is asked for.
    case signer
    /// The codes match: the PIN and the password approve, which completes the transfer.
    case approve
    case expired
    case rejected
    /// Approved, and the vault's `device.unlinked{transferred}` has not arrived yet (§6.7.1 step 4): this phone erases
    /// itself when it does; on a vault of release R it keeps its keys until then, for at most 7 days (§11.14.10). (When it
    /// arrives in time the app is already on the welcome screen.)
    case moved
}

/// The state of the transfer on the old phone. The PIN and the password live here only until the approval's answer; the
/// description names no secret. Mirrors vettid-android `TransferOutUiState`.
public struct TransferOutState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A vault PIN is 6 to 32 digits (§3.6.1).
    public static let minPin = 6
    public static let maxPin = 32

    public var step: TransferOutStep = .intro
    public var offer: TransferOfferView?
    public var pending: TransferPendingView?
    /// Until when the current step can go on: the code's expiry, then 10 minutes after the new phone's handshake.
    public var deadline: Date?
    public var secondsLeft: Int64 = 0
    public var pin = ""
    public var password = ""
    public var waitSeconds: Int64 = 0
    public var confirmReject = false
    public var confirmApprove = false
    /// The member confirmed the change of signer (``TransferOutStep/signer``): the approval names the new app's class.
    public var signerConfirmed = false
    /// The vault answered `signer_unconfirmed`: it wants the confirmation this app had not sent. Nothing was counted and
    /// the transfer is still open (the UTK of that attempt is spent, ANDROID-PLAN 0.1.58); the confirmation is shown, then
    /// the PIN and password again.
    public var signerUnconfirmed = false
    public var busy = false
    public var error: FailureKind?
    public var errorCode: String?
    /// (Release R, §11.14.10) After the approval this phone keeps its keys until the new phone has finished the move, for
    /// at most 7 days (``TransferOutStep/moved`` says so); false: it erases itself once the vault confirms.
    public var keptKeys = false
    /// (STAGING-TIME-SCALE, S10) How long it keeps them at most (7 days, divided by the time scale at the approval).
    public var keptForSeconds: Int64 = KeptTransfer.keepPeriodMs / 1000
    /// (STAGING-TIME-SCALE) A staging build adds its note to that text.
    public var stagingNote: String?

    public init() {}

    public var canApprove: Bool { pin.count >= Self.minPin && !password.isEmpty && waitSeconds == 0 && !busy }

    /// How long this phone keeps its keys, as the text says it ("7 days", "7 hours" on staging).
    public var keptForText: String { DurationText.of(TimeInterval(keptForSeconds)) }

    /// The confirmation's body when the signer changes (``TransferOutStep/signer``): the new phone's class named, and this
    /// phone's own when it has one.
    public var signerBody: String? {
        pending.map { SignerText.changeBody(new: SignerClass.of($0.signer), current: $0.currentSigner) }
    }

    public var description: String { "TransferOutState(step: \(step), busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What the transfer screens on the old phone can ask for: ``TransferOutViewModel``, or ``NoTransferOutActions`` in
/// previews and the screen catalog. Mirrors vettid-android `TransferOutActions`.
@MainActor
public protocol TransferOutActions: AnyObject, Sendable {
    func create()
    func codesMatch()
    /// ``TransferOutStep/signer``: the member read the change of signer and continues to the PIN.
    func confirmSigner()
    func askReject(_ show: Bool)
    func reject()
    /// The PIN from the keypad, handed over once.
    func setPin(_ v: String)
    func setPassword(_ v: String)
    func approve()
    func askApprove(_ show: Bool)
    func leave()
}

/// Actions that do nothing: the screens rendered with sample states (previews, the screen catalog).
@MainActor
public final class NoTransferOutActions: TransferOutActions {
    public init() {}

    public func create() {}
    public func codesMatch() {}
    public func confirmSigner() {}
    public func askReject(_ show: Bool) {}
    public func reject() {}
    public func setPin(_ v: String) {}
    public func setPassword(_ v: String) {}
    public func approve() {}
    public func askApprove(_ show: Bool) {}
    public func leave() {}
}

/// The old phone's side of a direct transfer (VAULT-MESSAGING §6.7.1), as vettid-vault's `vaultctl transfer`:
/// `device.transfer.create` gives the QR the new phone scans; `device.transfer.pending` brings the SAS once the new phone's
/// handshake checked out; the member compares it and approves with the PIN and the credential password
/// (`device.transfer.approve`), which completes the transfer: the vault then removes this phone and tells it
/// (`device.unlinked{transferred}`, after the new phone's first unlock from storage on release R, §11.14.10), and the app
/// erases itself. A mismatch rejects it. Mirrors vettid-android `TransferOutViewModel`; the clock and the waits are
/// injected (a virtual clock in the tests).
@MainActor
@Observable
public final class TransferOutViewModel: TransferOutActions {
    /// The approval window: 10 minutes after the new phone's `hs.init` (§6.7, 0.10.4), counted from the pending.
    static let window: TimeInterval = 600

    public private(set) var state = TransferOutState()

    @ObservationIgnored private let move: any MoveRepository
    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private var waiter: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var backoff: Task<Void, Never>?

    /// The steps in which the transfer is open at the vault: leaving cancels it, the deadline expires it.
    private static let openSteps: Set<TransferOutStep> = [.showing, .compare, .signer, .approve]
    private static let codeSignerUnconfirmed = "signer_unconfirmed"

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
        backoff?.cancel()
    }

    public func create() {
        if state.busy { return }
        state = TransferOutState()
        state.busy = true
        waiter?.cancel()
        // The task holds the model weakly and never across an await, and stops after any await if it was cancelled (Swift
        // cannot interrupt an await): a late offer or pending after `leave()` changes nothing.
        waiter = Task { @MainActor [weak self, move, now] in
            let offer: TransferOfferView
            do {
                offer = try await move.transferCreate()
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error, step: .intro)
                return
            }
            guard !Task.isCancelled, self != nil else {
                // The code was made after the member left: cancel it, so that it cannot be used (best effort; chosen, not in
                // the spec: vettid-android lets it expire). From a task of its own, as leave() does: this one is cancelled.
                Task { @MainActor [move, id = offer.transferID] in try? await move.transferReject(transferID: id) }
                return
            }
            // The strong reference lives only inside these blocks, never across an await.
            do {
                guard let vm = self else { return }
                vm.state.step = .showing
                vm.state.busy = false
                vm.state.offer = offer
                vm.state.deadline = offer.expiresAt
                vm.startTicker(offer.expiresAt)
            }
            let pending: TransferPendingView?
            do {
                pending = try await move.awaitTransferPending(transferID: offer.transferID, until: offer.expiresAt)
            } catch {
                guard !Task.isCancelled else { return }
                if let vm = self {
                    let f = Self.failure(of: error)
                    vm.state.error = f.kind
                    vm.state.errorCode = f.code
                    vm.expire()
                }
                return
            }
            guard !Task.isCancelled, let vm = self else { return }
            guard let pending else {
                vm.expire()
                return
            }
            // The approval window: 10 minutes after the new phone's hs.init (§6.7, 0.10.4), counted from here.
            let window = now().addingTimeInterval(Self.window)
            vm.state.step = .compare
            vm.state.pending = pending
            vm.state.deadline = window
            vm.state.error = nil
            vm.startTicker(window)
        }
    }

    private static func failure(of error: any Error) -> (kind: FailureKind, code: String?) {
        let e = error as? VaultFailure
        return (e?.kind ?? .other, e?.code)
    }

    private func fail(_ error: any Error, step: TransferOutStep? = nil) {
        let f = Self.failure(of: error)
        if let step { state.step = step }
        state.busy = false
        state.error = f.kind
        state.errorCode = f.code
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

    /// Shows the seconds left; false when the window is over (the transfer expires if it is still open).
    private func tickOnce(_ deadline: Date) -> Bool {
        let left = max(Int64(deadline.timeIntervalSince(now()).rounded(.down)), 0)
        state.secondsLeft = left
        if left == 0 {
            if Self.openSteps.contains(state.step) { expire() }
            return false
        }
        return true
    }

    private func expire() {
        waiter?.cancel()
        state.step = .expired
        state.offer = nil
        state.pending = nil
        state.pin = ""
        state.password = ""
        state.busy = false
        state.confirmApprove = false
        state.signerConfirmed = false
        state.signerUnconfirmed = false
    }

    /// §6.7.1 step 2 (0.27.0): when the signer differs, the app says so before it asks for the PIN.
    public func codesMatch() {
        let ask = state.pending?.signerChanged == true && !state.signerConfirmed
        state.step = ask ? .signer : .approve
        state.error = nil
    }

    public func confirmSigner() {
        guard state.step == .signer else { return }
        state.step = .approve
        state.signerConfirmed = true
        state.error = nil
    }

    public func askReject(_ show: Bool) { state.confirmReject = show }

    public func reject() {
        guard let id = state.offer?.transferID else { return }
        waiter?.cancel()
        ticker?.cancel()
        state.confirmReject = false
        state.busy = true
        work.launch { [weak self, move] in
            do {
                try await move.transferReject(transferID: id)
                var s = TransferOutState()
                s.step = .rejected
                self?.state = s
            } catch {
                self?.fail(error)
            }
        }
    }

    public func setPin(_ v: String) {
        state.pin = String(v.filter { $0.isASCII && $0.isNumber }.prefix(TransferOutState.maxPin))
        state.error = nil
    }

    public func setPassword(_ v: String) {
        state.password = v
        state.error = nil
    }

    public func askApprove(_ show: Bool) { state.confirmApprove = show && state.canApprove }

    /// Critical (§6.7.1): the PIN and the password, after the confirmation. Once the vault confirms, the app erases itself
    /// and leaves this screen (the phase changes); until then ``TransferOutStep/moved``.
    public func approve() {
        let s = state
        guard let id = s.offer?.transferID else { return }
        // Only from the approval step: never past the comparison or the confirmation of a changed signer.
        guard s.step == .approve, s.canApprove else { return }
        state.busy = true
        state.confirmApprove = false
        state.error = nil
        work.launch { [weak self, move, vault] in
            do {
                // §6.7.1 step 3: `signer` only as the member's confirmation, and exactly the class the vault named.
                let signer = s.signerConfirmed ? s.pending?.signer : nil
                let wiped = try await move.transferApprove(transferID: id, pin: s.pin, password: s.password, signer: signer)
                guard let self else { return }
                self.ticker?.cancel()
                self.state.step = wiped ? self.state.step : .moved
                self.state.busy = false
                self.state.pin = ""
                self.state.password = ""
                self.state.offer = nil
                self.state.keptKeys = vault.transferKeptSince != nil
                self.state.keptForSeconds = vault.transferKeepSeconds
                self.state.stagingNote = TimeScales.stagingNote(vault.timeScale)
            } catch {
                guard let self else { return }
                let f = Self.failure(of: error)
                if f.code == Self.codeSignerUnconfirmed {
                    self.signerUnconfirmed()
                    return
                }
                self.state.busy = false
                self.state.pin = ""
                self.state.password = ""
                self.state.error = f.kind
                self.state.errorCode = f.code
                let wait = (error as? VaultFailure)?.retryAfterSeconds ?? 0
                if wait > 0 { self.startBackoff(wait) }
            }
        }
    }

    /// `signer_unconfirmed` (§6.7.1 step 3, §11.7.1): the vault refused the approval before it tried the PIN, and the
    /// transfer stays open; (ANDROID-PLAN 0.1.58) the UTK of that attempt is spent, and the next approval takes a fresh one.
    /// Not a wrong PIN and no wait: the confirmation is shown (again, if the vault's view of the signer changed since the
    /// pending) and the next approval names the class. When the vault never named a class there is nothing to confirm with:
    /// the failure is shown as it is, named by its code.
    private func signerUnconfirmed() {
        state.busy = false
        state.pin = ""
        state.password = ""
        if state.pending?.signer == nil {
            state.error = .other
            state.errorCode = Self.codeSignerUnconfirmed
        } else {
            state.step = .signer
            state.signerConfirmed = false
            state.signerUnconfirmed = true
            state.error = nil
            state.errorCode = nil
        }
    }

    private func startBackoff(_ seconds: Int64) {
        backoff?.cancel()
        state.waitSeconds = seconds
        backoff = Task { @MainActor [weak self, sleep] in
            while !Task.isCancelled, (self?.state.waitSeconds ?? 0) > 0 {
                do {
                    try await sleep(.seconds(1))
                } catch {
                    return
                }
                guard let vm = self else { return }
                vm.state.waitSeconds = max(vm.state.waitSeconds - 1, 0)
            }
        }
    }

    /// Leaving before the approval cancels the transfer, so the code cannot be used later.
    public func leave() {
        let id = state.offer?.transferID
        let open = Self.openSteps.contains(state.step)
        waiter?.cancel()
        ticker?.cancel()
        backoff?.cancel()
        if let id, open {
            // Not cancelled with this model: leaving the screen clears it.
            Task { @MainActor [move] in
                // It expires within 10 minutes anyway.
                try? await move.transferReject(transferID: id)
            }
        }
        state = TransferOutState()
    }

    /// TEST ONLY: returns once what the model started has run as far as it can without a wait of the repository's or the
    /// clock's.
    func settle() async {
        for _ in 0..<100 { await Task.yield() }
        await work.settle()
    }
}
