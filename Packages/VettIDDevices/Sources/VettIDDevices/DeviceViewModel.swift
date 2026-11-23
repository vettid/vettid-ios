import Foundation
import Observation
import VettIDData

/// What the page's confirmation dialog is for.
public enum DeviceConfirm: Equatable, Sendable { case endAccess, remove }

/// What a failed request on a device's page says (the vault's own failure text for a refused owner check).
public enum DeviceFailure: Equatable, Sendable { case endAccess, remove }

/// A row of "Items it may use" (AA7): the item's name from the cache (nil when it does not resolve), and its ways. Holds an
/// item's name: nothing but the type is printed.
public struct WayItemRow: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let itemID: String
    public let name: String?
    /// The names of the items are read: a name still nil is then "An item you no longer have", never before.
    public let namesLoaded: Bool
    public let ways: [ItemWay]

    public init(itemID: String, name: String?, namesLoaded: Bool, ways: [ItemWay]) {
        self.itemID = itemID
        self.name = name
        self.namesLoaded = namesLoaded
        self.ways = ways
    }

    public var description: String { "WayItemRow" }
    public var debugDescription: String { "WayItemRow" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

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
    /// The device was removed here and its notice, "<name> was removed", was shown: the screen leaves.
    public var removed = false
    /// The device just removed here, until the screen leaves: the page shows its notice itself (opened from the feed it has no
    /// list under it to show it), and keeps the device on screen meanwhile.
    public var removedDevice: DeviceInfo?
    /// The list could not be read and no device is known: the page says so and offers Retry.
    public var loadError: FailureKind?
    /// AA7: the items the agent's rules include, with the ways each allows (`leash.item.list{agent_id}`); memory only.
    public var wayItems: [WayItemRow] = []
    public var wayItemsLoaded = false
    public var wayItemsError: FailureKind?
    /// The vault lists `item_ways` (decision 17): "Items it may use" is shown only then.
    public var wayItemsAvailable = false

    public init() {}

    /// This phone's own entry has no page (it has no actions).
    public var gone: Bool { loaded && (device == nil || device?.thisPhone == true) }

    public var description: String { "DeviceState" }
    public var debugDescription: String { "DeviceState" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A device's page (ANDROID-PLAN 0.1.53 AA1): its facts, End access (confirmed) and Remove (confirmed). It signs nothing and
/// never asks for the credential password: it holds only the device's id and the devices repository, so it has no way to
/// sign, to open the unlock window or to read anything else (AA7's items are read through a list-only interface:
/// ``ItemWaysList``, which holds nothing that saves). Fails secure: a request that fails leaves the page as it was and
/// says so. Mirrors vettid-android `DeviceViewModel`.
@MainActor
@Observable
public final class DeviceViewModel {
    @ObservationIgnored private let id: String
    @ObservationIgnored private let repo: any DevicesRepository
    @ObservationIgnored private let itemWays: (any ItemWaysList)?
    @ObservationIgnored private let items: (any ItemsRepository)?
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    /// The latest read of the items started: only its failure is shown (AA7).
    @ObservationIgnored private var wayItemsRead = 0
    @ObservationIgnored private var seenEvent: Int?
    private var local = DeviceState()
    /// The device as it was when a request failed or it was removed here: a hold clears the list (and with it the device)
    /// while the failure, the vault's refusal, is still to be read, and the page keeps naming it until the list is read again.
    private var kept: DeviceInfo?

    public init(id: String, repo: any DevicesRepository, itemWays: (any ItemWaysList)? = nil, items: (any ItemsRepository)? = nil) {
        self.id = id
        self.repo = repo
        self.itemWays = itemWays
        self.items = items
        seenEvent = itemWays?.event?.seq
        // A page opened from a feed item (or after a process start) may be the first reader of the list.
        refresh()
        if itemWays != nil { follows.add(follow(self, read: { $0.itemWays?.event }, apply: { $0.onWayEvent($1) })) }
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    public var state: DeviceState {
        var s = local
        s.loaded = repo.load == .loaded
        s.device = repo.devices.first { $0.id == id }
        if s.device == nil, let kept, s.removedDevice != nil || (!s.loaded && s.failure != nil) { s.device = kept }
        if let itemWays, s.device?.isAgent == true, itemWays.listed {
            s.wayItemsAvailable = true
            let names = Dictionary((items?.items ?? []).map { ($0.itemID, $0.name) }, uniquingKeysWith: { a, _ in a })
            let namesLoaded = items?.load == .loaded
            let read = itemWays.items[id]
            s.wayItemsLoaded = read != nil
            s.wayItems = (read ?? []).map {
                WayItemRow(itemID: $0.itemID, name: names[$0.itemID], namesLoaded: namesLoaded, ways: shownWays($0.rawWays))
            }
        }
        return s
    }

    /// The page is shown again (the item's page closed over it): the items are read again, since a way may have changed there.
    public func returned() { readWayItems() }

    /// **Try again** on the items that could not be read.
    public func refreshWayItems() { readWayItems() }

    /// A `leash.item.changed` of this agent, or a `share.rule.*` event (the rules read again): the items are read again.
    private func onWayEvent(_ e: ItemWaysEvent?) {
        guard let e, e.seq != seenEvent else { return }
        seenEvent = e.seq
        if e.concerns(id) { readWayItems() }
    }

    /// AA7: the items the agent's rules include, only with a vault that lists `item_ways` (decision 17).
    private func readWayItems() {
        guard let itemWays, itemWays.listed, state.device?.isAgent == true else { return }
        // The names come from the items' cache; a read nobody asked for fills it (as Approvals' and History's do).
        if let items, items.load != .loaded { items.refreshQuietly() }
        wayItemsRead += 1
        let mine = wayItemsRead
        let id = id
        work.launch { [weak self] in
            do {
                _ = try await itemWays.list(id)
                if self?.wayItemsRead == mine { self?.local.wayItemsError = nil }
            } catch where isSilent(error) {
                // Cut off by a lock or the app leaving.
            } catch {
                if self?.wayItemsRead == mine { self?.local.wayItemsError = failureKind(error) }
            }
        }
    }

    /// The daily check passed (or the hold ended): a page that could not read its device, or the hold cleared the list under,
    /// reads again (the page opened from the feed has no list screen to do it). The route calls it, so that the model holds
    /// nothing but the id and the repository.
    public func ownerCheckPassed() {
        guard repo.load != .loaded || local.loadError != nil else { return }
        refresh()
    }

    /// On opening, on Retry.
    public func refresh() {
        let repo = repo
        work.launch { [weak self] in
            do {
                try await repo.refresh()
                self?.local.loadError = nil
                self?.readWayItems()
            } catch where isSilent(error) {
                // Cut off by a lock or the app leaving.
            } catch {
                self?.local.loadError = failureKind(error)
            }
        }
    }

    public func askEndAccess() {
        guard !local.busy, local.removedDevice == nil, let d = state.device, d.actionable else { return }
        local.confirm = .endAccess
        local.failure = nil
        local.error = nil
    }

    /// Asks to remove the device. For an agent the confirmation names how long a service may still accept its permissions,
    /// which the vault is asked for first (the worst case when it cannot be: never a shorter time than true).
    public func askRemove() {
        guard let d = state.device, !local.busy, local.removedDevice == nil, d.actionable else { return }
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
        guard let d = state.device, d.actionable, !local.busy, local.removedDevice == nil, let what = local.confirm else { return }
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
                    guard let self else { return }
                    local.busy = false
                    // Told here, once: the list under the page (when there is one) has nothing left to say.
                    kept = d
                    local.removedDevice = d
                    repo.dismissRemoved()
                }
            } catch where isSilent(error) {
                self?.local.busy = false
            } catch {
                self?.local.busy = false
                self?.local.failure = what == .endAccess ? .endAccess : .remove
                self?.local.error = failureKind(error)
                self?.kept = d
                // What the vault says now settles whether the device is still there, with or without access. A failed read
                // is shown as the page's own (the hold clears the list: the refusal stays on the page, with the device).
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
    }

    public func accessEndedShown() { local.accessEnded = false }

    /// The notice's time is over: the page leaves.
    public func removedShown() { local.removed = true }

    public func dismissFailure() {
        local.failure = nil
        local.error = nil
    }

    /// TEST ONLY: returns once the work started so far has run.
    func settle() async { await work.settle() }
}
