import Foundation
import Observation
import VettIDData

/// The rotation's state: the password until the answer, never printed. Mirrors vettid-android `RotateUiState`.
public struct RotateState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var password = ""
    public var busy = false
    public var error: FailureKind?
    public var done = false

    public init(error: FailureKind? = nil, done: Bool = false) {
        self.error = error
        self.done = done
    }

    public var description: String { "RotateState(busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"), done: \(done))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// `credential.rotate` (VAULT-MESSAGING §3.5.5): a new credential key, every critical item re-keyed, the vault's `ik` and
/// `kem` rotated; the password only. Mirrors vettid-android `RotateViewModel`.
@MainActor
@Observable
public final class RotateViewModel {
    public private(set) var state = RotateState()

    @ObservationIgnored private let repo: any CredentialRepository
    @ObservationIgnored private let work = Work()

    public init(repo: any CredentialRepository) {
        self.repo = repo
    }

    deinit { work.cancelAll() }

    public func setPassword(_ v: String) {
        state.password = v
        state.error = nil
    }

    public func submit() {
        let pw = state.password
        guard !pw.isEmpty, !state.busy else { return }
        state.busy = true
        state.error = nil
        let repo = repo
        work.launch { [weak self] in
            do {
                try await repo.rotate(password: pw)
                self?.state = RotateState(done: true)
            } catch {
                self?.state = RotateState(error: failureKind(error))
            }
        }
    }

    /// Leaving the screen, or the app leaving the foreground or the iPhone locking (IOS-PLAN §6.3): the password goes. A
    /// rotation on its way stays busy.
    public func forgetSecrets() { state.password = "" }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}

/// The steps of answering a clone alarm (VAULT-MESSAGING §3.5.9). Mirrors vettid-android `AlarmStep`.
public enum AlarmStep: Equatable, Sendable { case ask, confirmMine, confirmNotMine, rotate, resolved }

/// The clone alarm screen's state; the password of the forced rotation until the answer, never printed. Mirrors
/// vettid-android `AlarmUiState`.
public struct AlarmState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var alarm: CredentialAlarm?
    public var step: AlarmStep = .ask
    /// The member answered "that was not me": the advice to change the password and the PIN follows.
    public var notMine = false
    public var password = ""
    public var busy = false
    public var error: FailureKind?

    public init(alarm: CredentialAlarm? = nil, step: AlarmStep = .ask) {
        self.alarm = alarm
        self.step = step
    }

    /// The step an alarm opens on: its answer, or the rotation it already waits for; resolved without one.
    public static func step(for a: CredentialAlarm?) -> AlarmStep {
        guard let a else { return .resolved }
        return a.rotationRequired ? .rotate : .ask
    }

    public var description: String { "AlarmState(step: \(step), busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The clone alarm (VAULT-MESSAGING §3.5.9): "that was me" or "not me", each confirmed (both move the alarm to
/// `rotation_required`), then the forced rotation with the password, which resolves it. On "not me" the app suggests
/// changing the password and the PIN. Follows the repository's alarm: another device's answer or rotation moves the
/// screen on. Mirrors vettid-android `AlarmViewModel`.
@MainActor
@Observable
public final class AlarmViewModel {
    public private(set) var state: AlarmState

    @ObservationIgnored private let repo: any CredentialRepository
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let followers = TaskBag()

    public init(repo: any CredentialRepository) {
        self.repo = repo
        state = AlarmState(alarm: repo.alarm, step: AlarmState.step(for: repo.alarm))
        followers.add(follow(self, read: { $0.repo.alarm }, apply: { $0.alarmChanged($1) }))
    }

    deinit {
        work.cancelAll()
        followers.cancelAll()
    }

    /// The alarm as the repository has it now: gone after one was shown is resolved; `rotation_required` moves to the
    /// rotation (unless already resolved).
    private func alarmChanged(_ a: CredentialAlarm?) {
        if let a {
            if a.rotationRequired, state.step != .resolved { state.step = .rotate }
            state.alarm = a
        } else if state.alarm != nil {
            state.step = .resolved
            state.password = ""
        }
    }

    /// The member's answer, confirmed next ([mine]: "that was me").
    public func answer(mine: Bool) {
        state.step = mine ? .confirmMine : .confirmNotMine
        state.notMine = !mine
    }

    public func cancelAnswer() { state.step = .ask }

    public func confirm() {
        guard state.step == .confirmMine || state.step == .confirmNotMine, !state.busy else { return }
        let mine = state.step == .confirmMine
        state.busy = true
        state.error = nil
        let repo = repo
        work.launch { [weak self] in
            do {
                try await repo.confirmAlarm(mine: mine)
                guard let self else { return }
                state.busy = false
                if state.step != .resolved { state.step = .rotate }
            } catch {
                self?.state.busy = false
                self?.state.error = failureKind(error)
                self?.state.step = .ask
            }
        }
    }

    public func setPassword(_ v: String) {
        state.password = v
        state.error = nil
    }

    public func rotate() {
        let pw = state.password
        guard !pw.isEmpty, !state.busy else { return }
        state.busy = true
        state.error = nil
        let repo = repo
        work.launch { [weak self] in
            do {
                try await repo.rotate(password: pw)
                self?.state.busy = false
                self?.state.password = ""
                self?.state.step = .resolved
            } catch {
                self?.state.busy = false
                self?.state.error = failureKind(error)
                self?.state.password = ""
            }
        }
    }

    /// Leaving the screen, or the app leaving the foreground or the iPhone locking (IOS-PLAN §6.3): the password goes.
    public func forgetSecrets() { state.password = "" }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
