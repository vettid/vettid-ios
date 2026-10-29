import Foundation
import Testing
import VettIDData
@testable import VettIDHistory
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// What a row and an entry's screen show (ANDROID-PLAN §4 History): the device's name after what the row already shows,
/// "Removed device" only for a device no longer listed, nothing without the list or for a listed unnamed device, "(this
/// phone)"; the item, the export's summary, the signer; titles that drop a name gone or not known; the entry's lines in
/// order; the export's texts. Mirrors vettid-android `HistoryDeviceTest` and the texts of `HistoryExportScreen`.
@Suite struct HistoryRowsTests {
    static func rec(_ seq: Int64, _ kind: String, device: String? = nil, conn: String? = nil, ref: String? = nil, direction: String? = nil) -> AuditRecord {
        AuditRecord(AuditEntry(entryID: "e\(seq)", seq: seq, at: "2026-10-10T09:00:0\(seq % 10).000Z", kind: kind, connectionID: conn, deviceID: device, ref: ref, direction: direction, hash: "AQ=="))
    }

    static let devices = HistoryDevices(names: ["d-pixel": "Pixel 10 Pro", "d-desk": "Desktop", "d-self": ""], selfID: "d-self")

    func state(devices: HistoryDevices? = Self.devices, items: [String: String]? = nil) -> HistoryState {
        var s = HistoryState()
        s.connectionNames = ["c1": "Ada Lovelace", "c2": ""]
        s.devices = devices
        s.itemNames = items
        return s
    }

    @Test func rowsNameTheirDeviceAfterWhatTheyAlreadyShow() {
        let s = state()
        #expect(s.row(Self.rec(5, "message.sent", device: "d-desk", conn: "c1")).supporting == "\u{2068}Ada Lovelace\u{2069} · Desktop")
        let unlocked = s.row(Self.rec(4, "vault.unlocked", device: "d-pixel"))
        #expect(unlocked.title == "Vault unlocked" && unlocked.supporting == "Pixel 10 Pro" && unlocked.category == .vaultAccess)
        #expect(s.row(Self.rec(3, "vault.locked", device: "d-gone")).supporting == "Removed device")
        // No device, this phone's own app (listed without a name): the group, no placeholder.
        #expect(s.row(Self.rec(2, "vault.locked")).supporting == "Unlocks and daily checks")
        #expect(s.row(Self.rec(1, "owner_check.passed", device: "d-self")).supporting == "Unlocks and daily checks")
    }

    @Test func withoutTheDeviceListRowsNameNoDevice() {
        let s = state(devices: nil)
        #expect(s.row(Self.rec(4, "vault.unlocked", device: "d-pixel")).supporting == "Unlocks and daily checks")
        #expect(s.row(Self.rec(5, "message.sent", device: "d-desk", conn: "c1")).supporting == "\u{2068}Ada Lovelace\u{2069}")
    }

    @Test func connectionsItemsExportsAndSigners() {
        let s = state(items: ["it1": "Passport"])
        #expect(s.row(Self.rec(1, "message.received", conn: "c2")).supporting == "Name not shared yet")
        #expect(s.row(Self.rec(1, "message.received", conn: "c9")).supporting == "Removed connection")
        #expect(s.row(Self.rec(1, "item.revealed", ref: "it1")).supporting == "\u{2068}Passport\u{2069}")
        #expect(s.row(Self.rec(1, "item.revealed", ref: "it2")).supporting == "Deleted item")
        // Before the app holds the Vault list, no item is named.
        #expect(state().row(Self.rec(1, "item.revealed", ref: "it2")).supporting == "Vault (items, sharing, wallet)")
        #expect(s.row(Self.rec(1, "audit.exported", ref: "format=csv;count=40;seqs=1-40;filters=none")).supporting == "CSV · 40 entries")
        #expect(s.row(Self.rec(1, "device.signer_refused", ref: "unbound")).supporting == "No signer was recorded for it")
    }

    /// IOS-PLAN §4.1: a title names the connection, device or item, and drops a name gone or not known.
    @Test func titlesNameOnlyWhatIsKnown() {
        let s = state(items: ["it1": "GitHub token"])
        #expect(s.row(Self.rec(1, "identity.rotate_conflict", conn: "c1")).title == "Connection with \u{2068}Ada Lovelace\u{2069} paused")
        #expect(s.row(Self.rec(1, "identity.rotate_conflict", conn: "c2")).title == "Connection paused")
        #expect(s.row(Self.rec(1, "identity.rotate_conflict", conn: "c9")).title == "Connection paused")
        #expect(s.row(Self.rec(1, "push.registered", device: "d-pixel", ref: "apns")).title == "Notifications turned on for \u{2068}Pixel 10 Pro\u{2069}")
        #expect(s.row(Self.rec(1, "push.registered", device: "d-gone", ref: "apns")).title == "Notifications turned on")
        #expect(s.row(Self.rec(1, "leash.item.run", ref: "it1")).title == "An agent used \u{2068}GitHub token\u{2069}")
        #expect(s.row(Self.rec(1, "leash.item.run", ref: "it9")).title == "An agent used an item")
    }

    @Test func theFiltersInWords() {
        var s = state()
        #expect(s.filterWords(dates: nil) == "All of your history")
        s.filter = AuditFilter(category: .messages, connectionID: "c1", query: "ada", since: Date())
        #expect(s.filterWords(dates: "Last 7 days") == "Messages and calls · Ada Lovelace · Last 7 days · “ada”")
        s.filter = AuditFilter(connectionID: "c9")
        #expect(s.filterWords(dates: "Last 7 days") == "Removed connection")
        #expect(s.exportContext.connectionNames["c2"] == "" && s.exportContext.itemNames == nil)
    }

    func entry(_ r: AuditRecord, _ configure: (inout HistoryEntryState) -> Void = { _ in }) -> HistoryEntryState {
        var s = HistoryEntryState()
        s.entry = r
        s.loading = false
        configure(&s)
        return s
    }

    @Test func theEntryPageNamesTheDeviceAndMarksThisPhone() {
        let mine = entry(Self.rec(4, "vault.unlocked", device: "d-pixel")) { $0.deviceName = "Pixel 10 Pro"; $0.devicesKnown = true; $0.thisDevice = true }
        #expect(mine.deviceLabel == "Pixel 10 Pro (this phone)")
        #expect(mine.fields().contains(HistoryField(label: "Device ID", value: "d-pixel", mono: true)))
        let other = entry(Self.rec(4, "vault.unlocked", device: "d-desk")) { $0.deviceName = "Desktop"; $0.devicesKnown = true }
        #expect(other.deviceLabel == "Desktop")
        let removed = entry(Self.rec(3, "vault.locked", device: "d-gone")) { $0.devicesKnown = true }
        #expect(removed.deviceLabel == "Removed device")
        let selfUnnamed = entry(Self.rec(4, "owner_check.passed", device: "d-self")) { $0.devicesKnown = true; $0.deviceUnnamed = true; $0.thisDevice = true }
        #expect(selfUnnamed.deviceLabel == "This phone")
        // Another unnamed device, or no device list: the id alone, no device line.
        let unnamed = entry(Self.rec(4, "vault.unlocked", device: "d-other")) { $0.devicesKnown = true; $0.deviceUnnamed = true }
        #expect(unnamed.deviceLabel == nil && !unnamed.fields().contains { $0.id == "history_entry_device" } && unnamed.fields().contains { $0.value == "d-other" })
        #expect(entry(Self.rec(4, "vault.unlocked", device: "d-pixel")).deviceLabel == nil)
        // No device: no device line at all.
        #expect(!entry(Self.rec(2, "vault.locked")) { $0.devicesKnown = true }.fields().contains { $0.label.hasPrefix("Device") })
    }

    @Test func theEntryPageListsItsLinesInOrder() {
        let s = entry(Self.rec(7, "recovery.attempt", conn: "c1", ref: "2/3/not_success/counter", direction: "in")) { $0.connectionName = "Ada Lovelace"; $0.connectionExists = true; $0.outcome = .matched("wrong") }
        let f = s.fields()
        #expect(f.map(\.label) == ["When", "Category", "Details", "Connection", "Direction", "Event type", "Reference", "Entry number", "Entry ID", "Entry hash"])
        #expect(f[2].value == "Not successful. If this was not you, change your PIN or your password now.\nWrong PIN or password.")
        #expect(f[3].value == "\u{2068}Ada Lovelace\u{2069}" && f[4].value == "Incoming" && f[5].value == "recovery.attempt" && f[5].mono)
        #expect(s.title == "Recovery attempt 3 of 10")
        let gone = entry(Self.rec(7, "message.sent", conn: "c9")) { _ in }
        #expect(gone.connectionLabel == "Removed connection")
        let unnamed = entry(Self.rec(7, "identity.rotate_conflict", conn: "c2")) { $0.connectionExists = true }
        #expect(unnamed.connectionLabel == "Name not shared yet" && unnamed.title == "Connection paused")
        let item = entry(Self.rec(7, "item.revealed", ref: "it1")) { $0.itemsKnown = true }
        #expect(item.itemLabel == "Deleted item" && item.fields().contains { $0.id == "history_entry_item" })
        #expect(!entry(Self.rec(7, "item.revealed", ref: "it1")).fields().contains { $0.id == "history_entry_item" })
        let signer = entry(Self.rec(7, "device.signer_refused", ref: "unpinned"))
        #expect(signer.fields().contains(HistoryField(label: "Version of VettID", value: "This vault release does not accept its signer", id: "history_entry_signer")))
        #expect(HistoryEntryState().fields().isEmpty && HistoryEntryState().title.isEmpty)
    }

    @Test func theExportsTexts() {
        var p = AuditExportAnswer(count: 40, uptoSeq: 90, uptoHash: "AA==")
        #expect(HistoryExportTexts.countAndRange(p) == "40 entries")
        p.oldestAt = "2026-10-08T10:00:00.000Z"
        p.newestAt = "2026-10-01T10:00:00.000Z"
        let a = HistoryExportTexts.day(ISO8601DateFormatter().date(from: "2026-10-01T10:00:00Z")!)
        let b = HistoryExportTexts.day(ISO8601DateFormatter().date(from: "2026-10-08T10:00:00Z")!)
        #expect(HistoryExportTexts.countAndRange(p) == "40 entries, \(a) – \(b)")
        #expect(HistoryExportTexts.done(written: 3, authorised: 3) == "3 entries exported.")
        #expect(HistoryExportTexts.done(written: 1, authorised: 1) == "1 entry exported.")
        #expect(HistoryExportTexts.done(written: 38, authorised: 40) == "38 of 40 entries exported; 2 older entries were removed by your vault's history limit meanwhile.")
        let now = Date()
        var pin = ExportPin(preview: p, format: .csv)
        #expect(HistoryExportTexts.pinError(pin, now: now) == nil)
        pin.error = .badPin
        #expect(HistoryExportTexts.pinError(pin, now: now) == "Wrong PIN")
        pin.error = .backoff
        pin.retryUntil = now.addingTimeInterval(59.2)
        #expect(HistoryExportTexts.pinError(pin, now: now) == "Too many wrong PINs. Try again in 60 s.")
        #expect(HistoryExportTexts.pinError(pin, now: now.addingTimeInterval(60)) == "Too many wrong PINs. Try again later.")
        pin.error = .network
        pin.retryUntil = nil
        #expect(HistoryExportTexts.pinError(pin, now: now) == FailureKind.network.message)
        #expect(pin.canSend(pinLength: 6, now: now) && !pin.canSend(pinLength: 5, now: now) && !pin.canSend(pinLength: 33, now: now))
    }
}

// swiftlint:enable line_length
