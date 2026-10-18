import Foundation
import Observation
import VettIDData

/// The steps of the name change. Mirrors vettid-android `ChangeNameStep`.
public enum ChangeNameStep: Equatable, Sendable {
    /// The two names, checked against the registration rule before anything else.
    case names
    /// The PIN and the credential password, on one screen, as for the owner check.
    case confirm
    /// Sent: the request's state (pending, then applied or refused) as the account reports it.
    case sent
}

/// What the confirm step says about the last answer. Mirrors vettid-android `ChangeNameMessage`.
public enum ChangeNameMessage: Equatable, Sendable {
    case badPin(checksLeft: Int?)
    case badPassword(checksLeft: Int?)
    case backoff
    /// The vault (or VettID) did not accept the names.
    case invalid
    case failed(FailureKind)
}

/// The name change's state. The PIN is here only from the member's "Change name" until the answer, the password only
/// until the answer or until the member goes back (as for the owner check, §3.6.5). Never printed: the description
/// names no secret. Mirrors vettid-android `ChangeNameUiState`.
public struct ChangeNameState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let minPin = 6
    public static let maxPin = 32

    public var step: ChangeNameStep = .names
    public var account: AccountInfo?
    public var first = ""
    public var last = ""
    /// Set once the member asked to continue: the field errors are shown from then on.
    public var checked = false
    public var pin = ""
    public var password = ""
    public var busy = false
    public var message: ChangeNameMessage?
    public var waitSeconds: Int64 = 0
    /// `too_soon` from the vault: [allowedAfter] is when the next change may be applied (nil: not said).
    public var tooSoon = false
    public var allowedAfter: Date?
    /// The request sent from this screen, updated from the account (`name_request`).
    public var request: NameRequestView?

    public init(account: AccountInfo? = nil) {
        self.account = account
        first = account?.firstName ?? ""
        last = account?.lastName ?? ""
    }

    public var firstCheck: AccountNames.Check { AccountNames.check(first) }
    public var lastCheck: AccountNames.Check { AccountNames.check(last) }

    /// Both names equal the current ones (the vault answers `bad_request`).
    public var same: Bool {
        guard let a = account, let current = a.firstName else { return false }
        return AccountNames.normalize(first) == current && AccountNames.normalize(last) == a.lastName
    }

    public var namesValid: Bool { firstCheck == .ok && lastCheck == .ok && !same }

    /// "First Last" as it will be sent.
    public var requestedName: String { "\(Self.trimSpaces(first)) \(Self.trimSpaces(last))" }

    /// Whether the PIN and the password may be sent now (the PIN's length is the keypad's, checked by the screen).
    public var entriesAllowed: Bool { step == .confirm && !busy && waitSeconds == 0 }

    public var submitAllowed: Bool { entriesAllowed && pin.count >= Self.minPin && !password.isEmpty }

    public var description: String {
        "ChangeNameState(step: \(step), busy: \(busy), message: \(message.map { "\($0)" } ?? "nil"), wait: \(waitSeconds), "
            + "request: \(request.map { "\($0.seq) \($0.state)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// Leading and trailing U+0020 only (VAULT-MESSAGING §10.8, 0.19.0).
    static func trimSpaces(_ s: String) -> String {
        String(s.drop { $0 == " " }.reversed().drop { $0 == " " }.reversed())
    }
}

/// Changing the account's first and last name (VAULT-MESSAGING §10.8, ANDROID-PLAN 0.1.10): the two names, checked with
/// the registration rule before the PIN and the password are asked for; then the PIN and the credential password on one
/// screen, sent with the names in one `account.name.set` and dropped once the vault answered; then the request as the
/// account reports it: pending, applied or refused. `too_soon` (from the snapshot, the vault or the member API) says when
/// the next change may be made. Mirrors vettid-android `ChangeNameViewModel`.
@MainActor
@Observable
public final class ChangeNameViewModel {
    /// A generous input bound; the rule's 40 is checked with its own message.
    public static let maxInput = 80

    private var local: ChangeNameState

    @ObservationIgnored private let accounts: any AccountRepository
    @ObservationIgnored private let profiles: any ProfileRepository
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let tick: @Sendable () async throws -> Void
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init(
        accounts: any AccountRepository,
        profiles: any ProfileRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        tick: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    ) {
        self.accounts = accounts
        self.profiles = profiles
        self.now = now
        self.tick = tick
        local = ChangeNameState(account: accounts.account)
        work.launch { await accounts.refreshAccount() }
    }

    deinit {
        work.cancelAll()
        ticker?.cancel()
    }

    /// The state now: the account as the repository has it (observed through it), the request sent from here updated from
    /// it, with this screen's own.
    public var state: ChangeNameState {
        var s = local
        let a = accounts.account
        s.account = a
        if let ours = s.request, let latest = a?.nameRequest, latest.seq == ours.seq { s.request = latest }
        return s
    }

    /// Whether the snapshot says a change now would be refused (`name_change.allowed_after` ahead).
    public func tooSoonBySnapshot() -> Bool { accounts.account?.nameChangeTooSoon(now: now()) == true }

    public func setFirst(_ v: String) { local.first = String(v.prefix(Self.maxInput)) }

    public func setLast(_ v: String) { local.last = String(v.prefix(Self.maxInput)) }

    /// From the names to the PIN and password, only with names the rule accepts.
    public func next() {
        local.checked = true
        local.account = accounts.account
        guard state.namesValid, !tooSoonBySnapshot() else { return }
        local.step = .confirm
        local.message = nil
    }

    /// Back from the PIN and password to the names; nothing entered there is kept.
    public func back() {
        ticker?.cancel()
        local.step = .names
        local.pin = ""
        local.password = ""
        local.message = nil
        local.waitSeconds = 0
    }

    /// Leaves the flow (or the app leaves the foreground): forgets the PIN and the password.
    public func cancel() {
        ticker?.cancel()
        local.pin = ""
        local.password = ""
        local.message = nil
    }

    /// The PIN from the keypad, handed over once, right before ``submit()``.
    public func setPin(_ v: String) {
        local.pin = String(v.filter { $0.isASCII && $0.isNumber }.prefix(ChangeNameState.maxPin))
        local.message = nil
    }

    public func setPassword(_ v: String) {
        local.password = v
        local.message = nil
    }

    public func submit() {
        let s = local
        guard s.submitAllowed else {
            // Refused here: the PIN handed over for it does not stay in memory.
            local.pin = ""
            return
        }
        local.busy = true
        local.message = nil
        let profiles = profiles
        work.launch { [weak self] in
            let r = await profiles.changeName(pin: s.pin, password: s.password, firstName: s.first, lastName: s.last)
            guard let self else { return }
            // Neither secret is kept beyond the answer (as for the owner check, §3.6.5).
            local.busy = false
            local.pin = ""
            local.password = ""
            apply(r)
        }
    }

    private func apply(_ r: NameChangeOutcome) {
        switch r {
        case .requested(let request):
            local.step = .sent
            local.request = request
        case .tooSoon(let after):
            local.step = .names
            local.tooSoon = true
            local.allowedAfter = after
        case .invalid:
            local.step = .names
            local.message = .invalid
        case .badPin(let left): local.message = .badPin(checksLeft: left)
        case .badPassword(let left): local.message = .badPassword(checksLeft: left)
        case .backoff(let wait):
            local.message = .backoff
            startBackoff(wait)
        case .failed(let kind, _): local.message = .failed(kind)
        }
    }

    private func startBackoff(_ seconds: Int64) {
        guard seconds > 0 else { return }
        ticker?.cancel()
        local.waitSeconds = seconds
        let tick = tick
        ticker = Task { @MainActor [weak self] in
            while (self?.local.waitSeconds ?? 0) > 0 {
                do {
                    try await tick()
                } catch {
                    return
                }
                guard let self else { return }
                local.waitSeconds = max(local.waitSeconds - 1, 0)
            }
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
