import Foundation
import Observation
import VettIDData

/// The Devices & agents list's state (ANDROID-PLAN 0.1.53 AA1). The devices and their names are the devices' own words: never
/// printed, dumped or mirrored. Mirrors vettid-android `DevicesUiState`.
public struct DevicesState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// This phone first, then agents, then desktops.
    public var devices: [DeviceInfo] = []
    public var load = ListLoad.notLoaded
    public var error: FailureKind?
    /// The device just removed on its page: the message "<name> was removed".
    public var removedDevice: DeviceInfo?

    public init() {}

    /// Only this phone is listed: "No agents yet". Only of a list that was read: one that was not never says it.
    public var onlyThisPhone: Bool { load == .loaded && devices.allSatisfy(\.thisPhone) }

    public var loading: Bool { devices.isEmpty && (load == .notLoaded || load == .loading) && error == nil }

    public var description: String { "DevicesState(devices: \(devices.count), load: \(load), error: \(error.map { "\($0)" } ?? "nil"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The list of the member's devices and agents (ANDROID-PLAN 0.1.53 AA1): read when the screen opens and on return to it;
/// `sync.event`s re-read it in the repository. Held in memory only. A list refused because the daily check was due reads
/// again by itself once a check passes ([ownerChecks]). Work cut off by a lock or by the app leaving is silent. Mirrors
/// vettid-android `DevicesViewModel`.
@MainActor
@Observable
public final class DevicesViewModel {
    @ObservationIgnored private let repo: any DevicesRepository
    @ObservationIgnored private let ownerChecks: (any OwnerCheckRepository)?
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    private var local = DevicesState()

    public init(repo: any DevicesRepository, ownerChecks: (any OwnerCheckRepository)? = nil) {
        self.repo = repo
        self.ownerChecks = ownerChecks
        if ownerChecks != nil {
            follows.add(follow(self, read: { $0.ownerChecks?.ownerCheck }, apply: { $0.onOwnerCheck($1) }))
        }
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    public var state: DevicesState {
        var s = local
        s.devices = repo.devices
        s.load = repo.load
        s.removedDevice = repo.removed
        return s
    }

    /// The daily check passed (or the hold ended): a list refused because it was due reads again by itself, and so does one
    /// the hold cleared while the screen was open (chosen; not in the spec: Android's screen stays on its spinner then).
    private func onOwnerCheck(_ v: OwnerCheckView?) {
        guard v?.state == .ok else { return }
        guard local.error == .ownerCheckRequired || (local.error == nil && repo.load != .loaded) else { return }
        refresh()
    }

    /// On opening and on every return to the screen.
    public func refresh() {
        local.error = nil
        let repo = repo
        work.launch { [weak self] in
            do {
                try await repo.refresh()
            } catch where isSilent(error) {
                // A lock or the app leaving cut the read off: silent (the list is read again when the screen returns).
            } catch {
                self?.local.error = failureKind(error)
            }
        }
    }

    public func removedShown() { repo.dismissRemoved() }

    /// TEST ONLY: returns once the work started so far has run.
    func settle() async { await work.settle() }
}
