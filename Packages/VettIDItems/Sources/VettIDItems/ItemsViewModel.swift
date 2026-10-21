import Foundation
import Observation
import VettIDData

/// The Vault list's state. Mirrors vettid-android `ItemsUiState`.
public struct ItemsState: Equatable, Sendable {
    public var items: [ItemSummary] = []
    public var filter = ItemFilter()
    public var load: ListLoad = .notLoaded
    public var error: FailureKind?
    /// The code an unmapped refusal names (shown with ``error``), or nil.
    public var errorCode: String?

    public init(items: [ItemSummary] = [], filter: ItemFilter = ItemFilter(), load: ListLoad = .notLoaded) {
        self.items = items
        self.filter = filter
        self.load = load
    }

    public var visible: [ItemSummary] { filter.apply(items) }

    /// The tags on the member's items, for the tag filter.
    public var tags: [String] { Array(Set(items.flatMap(\.tags))).sorted() }

    /// The categories in use, for the category filter: the recommended ones in their order, then the member's own (§10.7).
    public var categories: [String] {
        let used = Set(items.map(\.category))
        return ItemChecks.recommendedCategories.filter(used.contains) + ItemCategories.customs(used)
    }

    public var loading: Bool { items.isEmpty && (load == .notLoaded || load == .loading) }
}

/// The Vault list (ANDROID-PLAN §4): every item's metadata, searched and filtered on the phone. Mirrors vettid-android
/// `ItemsViewModel`.
@MainActor
@Observable
public final class ItemsViewModel {
    private var filter = ItemFilter()
    private var error: FailureKind?
    private var errorCode: String?

    @ObservationIgnored private let items: any ItemsRepository
    @ObservationIgnored private let ownerChecks: (any OwnerCheckRepository)?
    @ObservationIgnored let work = Work()
    @ObservationIgnored private let follows = TaskBag()

    public init(items: any ItemsRepository, ownerChecks: (any OwnerCheckRepository)? = nil) {
        self.items = items
        self.ownerChecks = ownerChecks
        refresh()
        // The daily check passed (or the hold ended): a list refused because it was due reads again by itself.
        if ownerChecks != nil {
            follows.add(follow(self, read: { $0.ownerChecks?.ownerCheck?.state }, apply: { m, s in
                if s == .ok, m.error == .ownerCheckRequired { m.refresh() }
            }))
        }
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    /// The state now: the list as the repository has it (observed through it), with this screen's filter and failure.
    public var state: ItemsState {
        var s = ItemsState(items: items.items, filter: filter, load: items.load)
        s.error = error
        s.errorCode = errorCode
        return s
    }

    public func refresh() {
        error = nil
        let items = items
        work.launch { [weak self] in
            do {
                try await items.refresh()
            } catch {
                let f = error as? VaultFailure ?? VaultFailure(.other)
                self?.errorCode = f.code
                self?.error = f.kind
            }
        }
    }

    public func setQuery(_ q: String) { filter.query = q }

    /// One tag at a time; the selected one again clears it.
    public func setTag(_ tag: String?) { filter.tag = tag == filter.tag ? nil : tag }

    public func setCategory(_ c: String?) { filter.category = c == filter.category ? nil : c }

    public func setSensitivity(_ s: Sensitivity?) { filter.sensitivity = s == filter.sensitivity ? nil : s }

    public func clearFilters() { filter = ItemFilter() }

    /// TEST ONLY: waits until the screen's work is done.
    func settle() async { await work.settle() }
}
