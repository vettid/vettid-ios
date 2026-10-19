import Foundation
import Observation
import VettIDData

/// The owner-check rows of Settings (VAULT-MESSAGING §3.6.2, §3.6.7). Mirrors vettid-android `OwnerCheckSettingsUiState`.
public struct OwnerCheckSettingsState: Equatable, Sendable {
    /// Nil for a vault that has not reported its owner check (not read yet).
    public var view: OwnerCheckView?
    public var busy = false
    public var error: FailureKind?
    /// The interval was shortened: a check is offered with the change (VAULT-MESSAGING §3.6.2).
    public var offerCheck = false
    /// (STAGING-TIME-SCALE §5.2) The vault's time scale: the interval is shown in real units with its scaled value.
    public var timeScale: UInt64

    public init(
        view: OwnerCheckView? = nil, busy: Bool = false, error: FailureKind? = nil, offerCheck: Bool = false, timeScale: UInt64 = 1
    ) {
        self.view = view
        self.busy = busy
        self.error = error
        self.offerCheck = offerCheck
        self.timeScale = timeScale
    }

    /// [text] for an interval of [hours] with its scaled value on a staging vault ("Every 24 hours (staging: 1 hour)",
    /// STAGING-TIME-SCALE §3 rule 3).
    public func interval(_ text: String, hours: Int) -> String {
        TimeScales.withStaging(text, TimeInterval(hours) * 3_600, by: timeScale)
    }

    /// "Staging: 1 day = 1 hour" on a staging vault; nil otherwise.
    public var stagingNote: String? { TimeScales.stagingNote(timeScale) }

    /// The interval in whole hours, at least 1.
    public var intervalHours: Int { max(Int((view?.intervalSeconds ?? OwnerCheckView.maxIntervalSeconds) / 3_600), 1) }
}

/// The interval (1–24 h) and the hold switch (VAULT-MESSAGING §3.6.2, §3.6.7); the check itself is the owner-check screen's. Mirrors
/// vettid-android `OwnerCheckSettingsViewModel`.
@MainActor
@Observable
public final class OwnerCheckSettingsViewModel {
    public static let secondsPerHour: Int64 = 3_600
    /// The interval choices (VAULT-MESSAGING §3.6.2: 1–24 h).
    public static let intervalHours = [1, 2, 4, 8, 12, 24]

    private var busy = false
    private var error: FailureKind?
    private var offerCheck = false

    @ObservationIgnored private let repo: any OwnerCheckRepository
    @ObservationIgnored private let work = Work()

    /// Reads the vault's owner check at once (quietly).
    public init(repo: any OwnerCheckRepository) {
        self.repo = repo
        work.launch { [repo] in try? await repo.refreshOwnerCheck() }
    }

    deinit { work.cancelAll() }

    public var state: OwnerCheckSettingsState {
        OwnerCheckSettingsState(view: repo.ownerCheck, busy: busy, error: error, offerCheck: offerCheck, timeScale: repo.timeScale)
    }

    /// A shorter interval applies at once and may put the vault on hold: a check is offered with it.
    public func setIntervalHours(_ hours: Int) {
        let seconds = Int64(hours) * Self.secondsPerHour
        let before = repo.ownerCheck?.intervalSeconds ?? OwnerCheckView.maxIntervalSeconds
        guard seconds != before else { return }
        act({ repo in try await repo.setCheckInterval(seconds: seconds) }, then: { m in
            if seconds < before { m.offerCheck = true }
        })
    }

    /// Turning the hold back on is a plain setting; turning it off is a check (the shell's owner-check screen).
    public func turnHoldOn() { act({ repo in try await repo.turnHoldOn() }) }

    public func dismissOffer() { offerCheck = false }

    public func dismissError() { error = nil }

    /// Runs [body] against the repository (the model is not held while it runs: a screen that went away cancels it),
    /// then, on success, [then] on the model if it is still there.
    private func act(
        _ body: @escaping @MainActor (any OwnerCheckRepository) async throws -> Void,
        then: @escaping @MainActor (OwnerCheckSettingsViewModel) -> Void = { _ in }
    ) {
        busy = true
        error = nil
        let repo = repo
        work.launch { [weak self] in
            var failed: FailureKind?
            do {
                try await body(repo)
            } catch {
                failed = failureKind(error)
            }
            guard let self else { return }
            busy = false
            error = failed
            if failed == nil { then(self) }
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
