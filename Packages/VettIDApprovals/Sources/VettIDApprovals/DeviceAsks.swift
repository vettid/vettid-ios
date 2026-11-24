import Foundation
import VettIDData

/// What a request an agent holds for approval shows and allows (ANDROID-PLAN 0.1.116 §4 "Approvals for devices and agents
/// (AA5)", 0.1.137 AA8). Pure: the screens and the view models both read it. Nothing is ever approved that is not shown in full
/// (decisions 10 and 15). Names are the item list's, cleaned, never a value. Mirrors vettid-android `HeldShow`.
public enum HeldShow: Equatable, Sendable, CustomStringConvertible {
    /// `item.use`: the item and field names, and the data as the member reads it (decision 18).
    case use(item: String, field: String, data: DataView, bytes: Int)
    /// `item.get`: the item and the field labels, or nil for all fields and notes.
    case get(item: String, fields: [String]?)
    case catalog
    /// The item (or a field) is not in the app's item list: "an item you no longer have", deny only. [loading]: the list is
    /// still being read.
    case noItem(use: Bool, loading: Bool)
    /// An op this version shows by a later one (a run and a proxy until their screens), the item named when known.
    case later(item: String?, loading: Bool)
    /// The item list could not be read, so what the request is about cannot be named, nor said to be gone: deny only until a
    /// read answers.
    case itemsUnread
    case desktop
    case other

    /// Whether Approve is offered.
    public var approvable: Bool {
        switch self {
        case .use, .get, .catalog: true
        default: false
        }
    }

    /// Never what the agent chose.
    public var description: String { "HeldShow" }
}

/// How far the item list a held request is named from has been read.
public enum ItemsRead: Equatable, Sendable {
    /// Not read yet, or being read for the first time since it was dropped (a lock).
    case reading
    /// Read: what it does not name is gone.
    case read
    /// The read failed: what it does not name is not known to be gone.
    case failed

    /// The list's [load], where [settled] says whether it was read since it was last dropped (and is kept up to date): a
    /// re-read on its way keeps a read list read; a drop (a lock) starts over; a failed read is never a read.
    public static func of(_ load: ListLoad, settled: inout Bool) -> ItemsRead {
        switch load {
        case .loaded:
            settled = true
            return .read
        case .notLoaded:
            settled = false
            return .reading
        case .loading: return settled ? .read : .reading
        case .failed: return .failed
        }
    }
}

public enum DeviceAsks {
    /// What [d], an `approval.pending`, shows, given the item list. [read]: how far the list has been read. Only once it has been
    /// read is what it cannot name "an item you no longer have": until then "Loading…", and after a failed read
    /// ``HeldShow/itemsUnread``.
    public static func show(_ d: DeviceRequest, items: [ItemSummary], read: ItemsRead = .read) -> HeldShow {
        let shown = showLoaded(d, items)
        switch (shown, read) {
        case (_, .read): return shown
        case (.noItem(let use, _), .reading): return .noItem(use: use, loading: true)
        case (.later(nil, _), .reading): return .later(item: nil, loading: true)
        case (.noItem, .failed), (.later(nil, _), .failed): return .itemsUnread
        default: return shown
        }
    }

    /// Whether [d] is an approval an agent or a desktop holds (not a session request).
    public static func isHeld(_ d: DeviceRequest) -> Bool { d.type == "approval.pending" }

    private static func showLoaded(_ d: DeviceRequest, _ items: [ItemSummary]) -> HeldShow {
        func item(_ id: String) -> ItemSummary? { items.first { $0.itemID.sameBytes(id) } }
        func label(_ i: ItemSummary?, _ field: String) -> String? {
            AccountNames.cleaned(i?.fieldLabels.first { $0.fieldID.sameBytes(field) }?.label)
        }
        switch d.held {
        case .itemUse(let itemID, let fieldID, let data)?:
            let i = item(itemID)
            guard let name = AccountNames.cleaned(i?.name), let field = label(i, fieldID) else { return .noItem(use: true, loading: false) }
            // More than `item.use` carries is never shown (``DataView/maxBytes``).
            guard let view = DataView.of(data) else { return .other }
            return .use(item: name, field: field, data: view, bytes: data.count)
        case .itemGet(let itemID, let ids)?:
            let i = item(itemID)
            let labels = ids?.map { label(i, $0) }
            // A field this phone cannot name is not shown unseen.
            guard let name = AccountNames.cleaned(i?.name), labels?.contains(where: { $0 == nil }) != true else {
                return .noItem(use: false, loading: false)
            }
            return .get(item: name, fields: labels?.compactMap { $0 })
        case .catalog?: return .catalog
        case .itemRun(let r)?: return .later(item: AccountNames.cleaned(item(r.itemID)?.name), loading: false)
        case .itemProxy(let p)?: return .later(item: AccountNames.cleaned(item(p.itemID)?.name), loading: false)
        case .desktopStepUp?: return .desktop
        case .unshown?, nil: return .other
        }
    }
}

/// A request an agent holds as one render of its screen showed it: the request, what it showed of it, and the approvals'
/// ``ApprovalsRepository/forgetCount`` then. Approve sends only this, and only while the screen still shows the same
/// (``ApprovalDetailViewModel/approve(shown:held:)``).
public struct ShownHeld: Equatable, Sendable, CustomStringConvertible {
    public var request: DeviceRequest
    public var show: HeldShow
    public var generation: Int

    public init(request: DeviceRequest, show: HeldShow, generation: Int) {
        self.request = request
        self.show = show
        self.generation = generation
    }

    /// Never what the agent chose.
    public var description: String { "ShownHeld" }
}

/// How a decision on a request an agent holds ended (said before the screen closes). Mirrors vettid-android `DeviceOutcome`.
public enum DeviceOutcome: Equatable, Sendable {
    /// `approval.decide{approve: true}` answered [result] (`ok`, or the code the held request was answered with); nil: no result.
    case approved(result: String?)
    /// `{result: "referred"}` (§6.8 step 4): not done yet; the new approval is a new entry, to be opened anew.
    case referred
    case denied
    /// The vault answered `not_found` as an error (replaced, decided elsewhere, dropped), or the request expired or was dropped
    /// here before it was sent: "This request is no longer waiting." (A `{result: "not_found"}` is an ``approved(result:)``.)
    case noLongerWaiting
}
