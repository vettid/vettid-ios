import Foundation
import VettIDData

/// What a History row shows: its title, its second line, and its group (the tile's colour and icon).
public struct HistoryRow: Equatable, Sendable {
    public var title: String
    public var supporting: String
    public var category: AuditCategory
}

public extension HistoryState {
    /// A connection as History names it: "First Last", "Name not shared yet" before the names arrived, "Removed
    /// connection" once it is gone.
    func connectionLabel(_ id: String) -> String {
        guard let name = connectionNames[id] else { return HistoryStrings.connectionRemoved }
        return AccountNames.isolateOrNull(name) ?? HistoryStrings.connectionUnnamed
    }

    /// ``connectionLabel(_:)`` without the isolation: for the export's confirm words, which go into a file's description.
    func connectionWords(_ id: String) -> String {
        guard let name = connectionNames[id] else { return HistoryStrings.connectionRemoved }
        return AccountNames.cleaned(name) ?? HistoryStrings.connectionUnnamed
    }

    /// A connection's "First Last" for a title; nil before the names arrived or once it is gone: the title drops it (IOS-PLAN
    /// §4.1: "never reads 'Connection with Removed connection paused'"; vettid-android names a removed device in a title).
    func connectionTitleName(_ id: String?) -> String? { id.flatMap { connectionNames[$0] }.flatMap { $0.isEmpty ? nil : $0 } }

    /// [r] as its row shows it (ANDROID-PLAN §4 History): the title, with the connection's, device's or item's name where
    /// IOS-PLAN §4.1 names it; then the item (or the export's format and count, or the signer in words), the connection
    /// and the device, else the group. Mirrors vettid-android `EntryRow`.
    func row(_ r: AuditRecord) -> HistoryRow {
        let e = r.entry
        let connection = e.connectionID.map(connectionLabel)
        let itemID = AuditKinds.itemOf(r.kind, e.ref)
        let item = itemID.flatMap { id in itemNames.map { AccountNames.isolateOrNull($0[id]) ?? HistoryStrings.itemDeleted } }
            ?? HistoryText.exportSummary(r.kind, e.ref)
            ?? AuditKinds.signerDetail(r.kind, e.ref).map(HistoryText.signer)
        let device = HistoryText.deviceName(e.deviceID, devices, isolate: true)
        let names = EntryNames(
            connection: connectionTitleName(e.connectionID), device: devices?.device(e.deviceID)?.rowName,
            item: itemID.flatMap { itemNames?[$0] }
        )
        return HistoryRow(
            title: HistoryText.title(r.kind, e.ref, names: names),
            supporting: HistoryText.supporting([item, connection, device], fallback: AuditKinds.categoryLabel(r.category)),
            category: r.category
        )
    }

    /// The list's filters in words for the export's confirm step ("Messages and calls · Alice Moreau · Last 7 days ·
    /// “ada”"), or "All of your history". [dates]: the date chip's label. Mirrors vettid-android `filterWords`.
    func filterWords(dates: String?) -> String {
        let f = filter
        let parts = [
            f.category.map(AuditKinds.categoryLabel), f.connectionID.map(connectionWords),
            f.since != nil || f.until != nil ? dates : nil, f.q.map(HistoryStrings.exportSearch),
        ].compactMap { $0 }
        return parts.isEmpty ? HistoryStrings.exportFiltersNone : parts.joined(separator: " · ")
    }

    /// What an export of the list exports: its filter and the names it shows.
    var exportContext: ExportContext { ExportContext(filter: filter, connectionNames: connectionNames, itemNames: itemNames) }
}

/// One line of an entry's screen: its label and value, in a monospaced face for identifiers.
public struct HistoryField: Equatable, Sendable {
    public var label: String
    public var value: String
    public var mono = false
    /// The field's identifier for UI tests, where it has one.
    public var id: String?
}

public extension HistoryEntryState {
    /// The entry's device as its screen names it (ANDROID-PLAN §4 History): its name ("Removed device" once unlisted),
    /// "(this phone)" for this one; nil without the device list, or for another device listed without a name (the id
    /// alone below).
    var deviceLabel: String? {
        guard entry?.entry.deviceID != nil else { return nil }
        let removed = devicesKnown && !deviceUnnamed
        let name = AccountNames.isolateOrNull(deviceName) ?? (removed ? HistoryStrings.deviceRemoved : nil)
        if thisDevice { return name.map(HistoryStrings.deviceThisPhone) ?? HistoryStrings.deviceThisPhoneAlone }
        return name
    }

    /// The title, with the connection's, device's or item's name where IOS-PLAN §4.1 names it.
    var title: String {
        guard let e = entry else { return "" }
        // A removed or unnamed device, a gone connection or item: the title drops the name.
        return HistoryText.title(e.kind, e.entry.ref, names: EntryNames(connection: connectionName, device: deviceName, item: itemName))
    }

    /// The connection's line: its name, "Name not shared yet", or "Removed connection".
    var connectionLabel: String {
        AccountNames.isolateOrNull(connectionName)
            ?? (connectionExists ? HistoryStrings.connectionUnnamed : HistoryStrings.connectionRemoved)
    }

    /// The item's line: its name, "Deleted item" once it is gone; nil while the app holds no item list.
    var itemLabel: String? { AccountNames.isolateOrNull(itemName) ?? (itemsKnown ? HistoryStrings.itemDeleted : nil) }

    /// The lines under the title, in vettid-android's order: when, the group, the details (IOS-PLAN §4.1), then the
    /// connection, the item, the signer, the direction, the kind, the device, the reference and the chain fields. The
    /// connection's and the item's buttons, and the reference's copy button, are the screen's.
    func fields(timeScale: UInt64 = 1) -> [HistoryField] {
        guard let r = entry else { return [] }
        let e = r.entry
        var out = [
            HistoryField(label: HistoryStrings.detailWhen, value: r.at.map(Self.fullTime) ?? HistoryStrings.detailUnknownTime),
            HistoryField(label: HistoryStrings.detailCategory, value: AuditKinds.categoryLabel(r.category)),
        ]
        let details = HistoryText.details(r.kind, e.ref, outcome: outcome, timeScale: timeScale)
        if !details.isEmpty {
            let label = HistoryKindTexts.text("history_detail_details")
            out.append(HistoryField(label: label, value: details.joined(separator: "\n"), id: "history_entry_details"))
        }
        if e.connectionID != nil {
            out.append(HistoryField(label: HistoryStrings.detailConnection, value: connectionLabel, id: "history_entry_connection"))
        }
        if AuditKinds.itemOf(r.kind, e.ref) != nil, let item = itemLabel {
            out.append(HistoryField(label: HistoryStrings.detailItem, value: item, id: "history_entry_item"))
        }
        if let s = AuditKinds.signerDetail(r.kind, e.ref) {
            let label = HistoryKindTexts.text("history_detail_signer")
            out.append(HistoryField(label: label, value: HistoryText.signer(s), id: "history_entry_signer"))
        }
        if let d = e.direction {
            let value = d == "in" ? HistoryStrings.detailDirectionIn : d == "out" ? HistoryStrings.detailDirectionOut : d
            out.append(HistoryField(label: HistoryStrings.detailDirection, value: value))
        }
        out.append(HistoryField(label: HistoryStrings.detailKind, value: r.kind, mono: true))
        if let id = e.deviceID {
            if let label = deviceLabel {
                out.append(HistoryField(label: HistoryStrings.detailDevice, value: label, id: "history_entry_device"))
            }
            out.append(HistoryField(label: HistoryStrings.detailDeviceId, value: id, mono: true))
        }
        if let ref = e.ref { out.append(HistoryField(label: HistoryStrings.detailRef, value: ref, mono: true, id: "history_entry_ref")) }
        out.append(HistoryField(label: HistoryStrings.detailSeq, value: String(r.seq), mono: true))
        out.append(HistoryField(label: HistoryStrings.detailId, value: e.entryID, mono: true))
        if !e.hash.isEmpty { out.append(HistoryField(label: HistoryStrings.detailHash, value: e.hash, mono: true)) }
        return out
    }

    /// The full date and time (vettid-android `Times.full`).
    static func fullTime(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
}
