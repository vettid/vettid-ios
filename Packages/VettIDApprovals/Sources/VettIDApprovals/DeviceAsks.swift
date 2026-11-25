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
    /// `item.run` (AA8): the run as the vault holds it, the item's and the field's names from the item list.
    case run(ItemRun, item: String, field: String)
    /// `item.proxy` (AA8): the proxy as the vault's note has it, the item's and the field's names from the item list.
    case proxy(ItemProxy, item: String, field: String)
    /// The item (or a field) is not in the app's item list: "an item you no longer have", deny only. [loading]: the list is
    /// still being read.
    case noItem(use: Bool, loading: Bool)
    /// An op this version shows by a later one (no longer used for a run or a proxy), the item named when known.
    case later(item: String?, loading: Bool)
    /// The item list could not be read, so what the request is about cannot be named, nor said to be gone: deny only until a
    /// read answers.
    case itemsUnread
    /// A run or a proxy whose item the list does not name, after a failed read: said without an item (it is not known to be
    /// gone), deny only as ``later(item:loading:)``.
    case laterUnread
    case desktop
    case other

    /// Whether Approve is offered.
    public var approvable: Bool {
        switch self {
        case .use, .get, .catalog, .run, .proxy: true
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

    /// The list's [load], where [readAt] is the list's ``ItemsRepository/cleared`` when it was last seen read (kept up to
    /// date) and [cleared] that count now: a re-read on its way keeps a list read since the last drop (a lock) read; one
    /// read before a drop never counts, even when nothing looked at the list between the drop and the next read; a failed
    /// read is never a read, and the read before it no longer counts either (the screen said the list could not be read).
    public static func of(_ load: ListLoad, cleared: Int, readAt: inout Int?) -> ItemsRead {
        switch load {
        case .loaded:
            readAt = cleared
            return .read
        case .notLoaded: return .reading
        case .loading: return readAt == cleared ? .read : .reading
        case .failed:
            readAt = nil
            return .failed
        }
    }
}

public enum DeviceAsks {
    /// What [d], an `approval.pending`, shows, given the item list. [read]: how far the list has been read. Only once it has been
    /// read is what it cannot name "an item you no longer have": until then "Loading…". After a failed read, a use or a reveal
    /// (what names an item and its fields), and a run or a proxy (which name one too, AA8), is ``HeldShow/itemsUnread``, so the
    /// screen says why Approve is off and offers Try again; an op shown by a later version keeps its text, without an item it
    /// cannot name (``HeldShow/laterUnread``); a catalog names no item and needs no list (``ApprovalDetailState/canApprove(at:)``).
    public static func show(_ d: DeviceRequest, items: [ItemSummary], read: ItemsRead = .read) -> HeldShow {
        let shown = showLoaded(d, items)
        switch (shown, read) {
        case (_, .read): return shown
        case (.noItem(let use, _), .reading): return .noItem(use: use, loading: true)
        case (.later(nil, _), .reading): return .later(item: nil, loading: true)
        case (.use, .failed), (.get, .failed), (.run, .failed), (.proxy, .failed), (.noItem, .failed): return .itemsUnread
        case (.later(nil, _), .failed): return .laterUnread
        default: return shown
        }
    }

    /// Whether [d] is an approval an agent or a desktop holds (not a session request).
    public static func isHeld(_ d: DeviceRequest) -> Bool { d.type == "approval.pending" }

    private static func showLoaded(_ d: DeviceRequest, _ items: [ItemSummary]) -> HeldShow { // swiftlint:disable:this cyclomatic_complexity
        func item(_ id: String) -> ItemSummary? { items.first { $0.itemID.sameBytes(id) } }
        func label(_ i: ItemSummary?, _ field: String) -> String? {
            AccountNames.cleaned(i?.fieldLabels.first { $0.fieldID.sameBytes(field) }?.label)
        }
        // The item's and the field's names as the list has them, cleaned; nil when either does not name.
        func named(_ i: ItemSummary?, _ fieldID: String) -> (String, String)? {
            guard let name = AccountNames.cleaned(i?.name), let field = label(i, fieldID) else { return nil }
            return (name, field)
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
        case .itemRun(let r)?:
            guard case let (name, field)? = named(item(r.itemID), r.fieldID) else { return .noItem(use: true, loading: false) }
            return .run(r, item: name, field: field)
        case .itemProxy(let p)?:
            guard case let (name, field)? = named(item(p.itemID), p.fieldID) else { return .noItem(use: true, loading: false) }
            return .proxy(p, item: name, field: field)
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
    /// [way]: a run or a proxy (AA8 has its own texts); [pinRecorded]: after an `ok` that records a fingerprint, the item's settings
    /// read since show it (AA8 "Approving and the pin"), for [item].
    case approved(result: String?, way: AgentWay? = nil, pinRecorded: Bool = false, item: String? = nil)
    /// `{result: "referred"}` (§6.8 step 4), for a run or a proxy: not done yet; the new approval is a new entry, to be opened anew.
    case referred
    case denied
    /// The vault answered `not_found` as an error (replaced, decided elsewhere, dropped), or the request expired or was dropped
    /// here before it was sent: "This request is no longer waiting." (A `{result: "not_found"}` is an ``approved(result:)``.)
    case noLongerWaiting
}

/// The two ways an agent uses a secret that AA8's screens show.
public enum AgentWay: Equatable, Sendable { case run, proxy }
