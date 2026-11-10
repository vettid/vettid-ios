import Foundation
import Observation
import VettIDData

/// What the page's confirmation dialog is for.
public enum DeviceConfirm: Equatable, Sendable { case endAccess, remove }

/// What a failed request on a device's page says (the vault's own failure text for a refused owner check).
public enum DeviceFailure: Equatable, Sendable { case endAccess, remove }

/// A device's page state (ANDROID-PLAN 0.1.53 AA1). Holds a device's name: nothing but the type is printed. Mirrors
/// vettid-android `DeviceUiState`.
public struct DeviceState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var device: DeviceInfo?
    /// The list was read at least once: a ``device`` still nil is a device that is no longer there.
    public var loaded = false
    public var confirm: DeviceConfirm?
    /// With ``DeviceConfirm/remove`` of an agent: seconds a service may still accept its permissions (0: none).
    public var removalBoundSeconds: Int64 = 0
    public var busy = false
    public var failure: DeviceFailure?
    public var error: FailureKind?
    /// "Access ended", once.
    public var accessEnded = false
    /// The device was removed here: the screen leaves.
    public var removed = false
    /// The list could not be read and no device is known: the page says so and offers Retry.
    public var loadError: FailureKind?

    public init() {}

    /// This phone's own entry has no page (it has no actions).
    public var gone: Bool { loaded && (device == nil || device?.thisPhone == true) }

    public var description: String { "DeviceState" }
    public var debugDescription: String { "DeviceState" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A device's page (ANDROID-PLAN 0.1.53 AA1): its facts, End access (confirmed) and Remove (confirmed). It signs nothing and
/// never asks for the credential password: it holds only the device's id and the devices repository, so it has no way to
/// sign, to open the unlock window or to read anything else. Fails secure: a request that fails leaves the page as it was and
/// says so. Mirrors vettid-android `DeviceViewModel`.
@MainActor
@Observable
public final class DeviceViewModel {
    @ObservationIgnored private let id: String
    @ObservationIgnored private let repo: any DevicesRepository
    @ObservationIgnored private let work = Work()
    private var local = DeviceState()

    public init(id: String, repo: any DevicesRepository) {
        self.id = id
        self.repo = repo
        // A page opened from a feed item (or after a process start) may be the first reader of the list.
        refresh()
    }

    deinit { work.cancelAll() }

    public var state: DeviceState {
        var s = local
        s.device = repo.devices.first { $0.id == id }
        s.loaded = repo.load == .loaded
        return s
    }

    /// On opening, on Retry.
    public func refresh() {
        let repo = repo
        work.launch { [weak self] in
            do {
                try await repo.refresh()
                self?.local.loadError = nil
            } catch where isSilent(error) {
                // Cut off by a lock or the app leaving.
            } catch {
                self?.local.loadError = failureKind(error)
            }
        }
    }

    public func askEndAccess() {
        guard !local.busy, let d = state.device, d.actionable else { return }
        local.confirm = .endAccess
        local.failure = nil
        local.error = nil
    }

    /// Asks to remove the device. For an agent the confirmation names how long a service may still accept its permissions,
    /// which the vault is asked for first (the worst case when it cannot be: never a shorter time than true).
    public func askRemove() {
        guard let d = state.device, !local.busy, d.actionable else { return }
        local.busy = true
        local.failure = nil
        local.error = nil
        let repo = repo
        work.launch { [weak self] in
            let bound = d.isAgent ? await repo.removalBoundSeconds(d.id) : 0
            guard let self else { return }
            local.busy = false
            local.confirm = .remove
            local.removalBoundSeconds = bound
        }
    }

    public func dismissConfirm() { local.confirm = nil }

    public func confirm() {
        guard let d = state.device, d.actionable, !local.busy, let what = local.confirm else { return }
        local.confirm = nil
        local.busy = true
        let repo = repo
        work.launch { [weak self] in
            do {
                switch what {
                case .endAccess:
                    try await repo.endAccess(d.id)
                    self?.local.busy = false
                    self?.local.accessEnded = true
                case .remove:
                    try await repo.remove(d.id)
                    self?.local.busy = false
                    self?.local.removed = true
                }
            } catch where isSilent(error) {
                self?.local.busy = false
            } catch {
                self?.local.busy = false
                self?.local.failure = what == .endAccess ? .endAccess : .remove
                self?.local.error = failureKind(error)
                // What the vault says now settles whether the device is still there, with or without access.
                try? await repo.refresh()
            }
        }
    }

    public func accessEndedShown() { local.accessEnded = false }

    public func dismissFailure() {
        local.failure = nil
        local.error = nil
    }

    /// TEST ONLY: returns once the work started so far has run.
    func settle() async { await work.settle() }
}
