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

public enum DeviceAsks {
    /// What [d], an `approval.pending`, shows, given the item list. [loaded]: the list has been read (loaded or failed): until
    /// then what it cannot name is "Loading…", not "an item you no longer have".
    public static func show(_ d: DeviceRequest, items: [ItemSummary], loaded: Bool = true) -> HeldShow {
        let shown = showLoaded(d, items)
        if loaded { return shown }
        switch shown {
        case .noItem(let use, _): return .noItem(use: use, loading: true)
        case .later(let item, _) where item == nil: return .later(item: nil, loading: true)
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
            return .use(item: name, field: field, data: DataView.of(data), bytes: data.count)
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

/// How a decision on a request an agent holds ended (said before the screen closes). Mirrors vettid-android `DeviceOutcome`.
public enum DeviceOutcome: Equatable, Sendable {
    /// `approval.decide{approve: true}` answered [result] (`ok`, or the code the held request was answered with); nil: no result.
    case approved(result: String?)
    /// `{result: "referred"}` (§6.8 step 4): not done yet; the new approval is a new entry, to be opened anew.
    case referred
    case denied
    /// The vault answered `not_found` (replaced, decided elsewhere, dropped): "This request is no longer waiting."
    case noLongerWaiting
}
