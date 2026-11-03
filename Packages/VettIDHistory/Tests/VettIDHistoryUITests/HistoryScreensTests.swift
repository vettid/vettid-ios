#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
import VettIDData
import VettIDDataTesting
@testable import VettIDHistory
@testable import VettIDHistoryUI
import VettIDUI
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The History screens: every state of the list, the entry and the export's steps rendered; the date chip's label; the
/// groups' colours and icons. Mirrors vettid-android `HistoryDeviceTest`'s screens, `CategoryHueTest` and the export
/// screen's states.
@MainActor
@Suite struct HistoryScreensTests {
    static func rec(_ seq: Int64, _ kind: String, conn: String? = nil, device: String? = nil, ref: String? = nil) -> AuditRecord {
        AuditRecord(AuditEntry(entryID: "e\(seq)", seq: seq, at: "2026-10-10T09:00:00.000Z", kind: kind, connectionID: conn, deviceID: device, ref: ref, hash: "AQ=="))
    }

    let chrome = ShellChrome(accountName: "Me", onMenu: {}, onAvatar: {})

    @Test func eachCategoryHasTheOwnersColourAndAnIcon() {
        let expected: [AuditCategory: CategoryHue] = [
            .vaultAccess: .green, .security: .amber, .dropped: .red, .connections: .teal, .messages: .blue, .items: .gold,
            .devices: .purple, .agents: .orange, .location: .indigo, .account: .grey, .other: .grey,
        ]
        #expect(Set(expected.keys) == Set(AuditCategory.allCases))
        for (c, h) in expected { #expect(HistoryVisuals.hue(c) == h, "\(c)") }
        #expect(Set(AuditCategory.allCases.map(HistoryVisuals.symbol)).count == AuditCategory.allCases.count)
    }

    @Test func theDateChipSaysThePresetOrTheRange() {
        var s = HistoryState()
        #expect(HistoryFilterRow.dateLabel(s) == "Any time")
        s.datePreset = .week
        #expect(HistoryFilterRow.dateLabel(s) == "Last 7 days")
        s.datePreset = .custom
        let since = ISO8601DateFormatter().date(from: "2026-10-02T00:00:00Z")!
        let until = ISO8601DateFormatter().date(from: "2026-10-05T00:00:00Z")!
        s.filter = AuditFilter(since: since, until: until)
        #expect(HistoryFilterRow.dateLabel(s) == HistoryStrings.dateRange(HistoryTimes.day(since), HistoryTimes.day(until.addingTimeInterval(-1))))
    }

    @Test func everyStateOfTheListRenders() {
        var loaded = HistoryState()
        loaded.loading = false
        loaded.end = true
        var full = loaded
        full.entries = [Self.rec(5, "message.sent", conn: "c1", device: "d-desk"), Self.rec(4, "vault.unlocked", device: "d-pixel"), Self.rec(3, "recovery.open", ref: "r/wrong"), Self.rec(2, "zebra.new")]
        full.connectionNames = ["c1": "Ada Lovelace"]
        full.devices = HistoryDevices(names: ["d-desk": "Desktop"])
        var more = full
        more.end = false
        more.loadingMore = true
        more.partial = true
        more.filter = AuditFilter(query: "ada")
        var broken = full
        broken.chainBroken = true
        var local = full
        local.localSearch = true
        local.filter = AuditFilter(query: "ada")
        var failed = HistoryState()
        failed.loading = false
        failed.error = .network
        var noMatch = loaded
        noMatch.filter = AuditFilter(category: .devices)
        // A read that failed with entries shown: they stay, under the failure.
        var stale = full
        stale.end = false
        stale.error = .noResponse
        stale.refreshFailed = true
        var nextPage = stale
        nextPage.refreshFailed = false
        for s in [HistoryState(), loaded, full, more, broken, local, failed, noMatch, stale, nextPage] {
            #expect(height(HistoryScreen(state: s, chrome: chrome, actions: HistoryActions())) > 0, "\(s)")
            #expect(height(HistoryScreen(state: s, chrome: nil, onBack: {}, actions: HistoryActions())) > 0, "\(s)")
        }
    }

    /// A next page that failed is the footer's "Try again" (`history_retry`); a failed refresh is said above the entries,
    /// with no "Try again" in the footer. Mirrors vettid-android's footer.
    @Test func theFooterRetriesOnlyAFailedNextPage() {
        var s = HistoryState()
        s.loading = false
        s.entries = [Self.rec(5, "message.sent")]
        s.error = .noResponse
        #expect(HistoryEntryList.footer(s) == .retry)
        s.refreshFailed = true
        #expect(HistoryEntryList.footer(s) == .none)
        s.error = nil
        s.refreshFailed = false
        #expect(HistoryEntryList.footer(s) == .more)
        s.end = true
        #expect(HistoryEntryList.footer(s) == .end)
        s.loadingMore = true
        #expect(HistoryEntryList.footer(s) == .loading)
    }

    /// A vault on hold, whatever read it refused: said as held above the entries ("History is on hold", no "Try again",
    /// not in the footer either), since the list reads again by itself once the daily check passes.
    @Test func aHeldReadIsSaidAsHeld() {
        #expect(HistoryStrings.heldTitle == "History is on hold")
        #expect(HistoryStrings.heldBody == "Your daily check is due. They'll show again once it's done.")
        #expect(HistoryFailureNotice.held(.ownerCheckRequired) && !HistoryFailureNotice.held(.network))
        var s = HistoryState()
        s.loading = false
        s.entries = [Self.rec(5, "message.sent")]
        s.error = .ownerCheckRequired
        #expect(HistoryEntryList.footer(s) == .none && HistoryEntryList.saysAbove(s))
        s.error = .network
        #expect(HistoryEntryList.footer(s) == .retry && !HistoryEntryList.saysAbove(s))
        var empty = HistoryState()
        empty.loading = false
        empty.error = .ownerCheckRequired
        s.error = .ownerCheckRequired
        for state in [s, empty] {
            #expect(height(HistoryScreen(state: state, chrome: chrome, actions: HistoryActions())) > 0)
        }
    }

    @Test func everyStateOfAnEntryRenders() {
        var s = HistoryEntryState()
        #expect(height(HistoryEntryScreen(state: s, actions: HistoryEntryActions())) > 0)
        s.loading = false
        s.missing = true
        #expect(height(HistoryEntryScreen(state: s, actions: HistoryEntryActions())) > 0)
        s.error = .network
        #expect(height(HistoryEntryScreen(state: s, actions: HistoryEntryActions())) > 0)
        s.error = nil
        s.missing = false
        s.entry = Self.rec(9, "recovery.attempt", conn: "c1", device: "d-self", ref: "2/3/not_success/counter")
        s.connectionName = "Ada Lovelace"
        s.connectionExists = true
        s.devicesKnown = true
        s.deviceUnnamed = true
        s.thisDevice = true
        s.outcome = .matched("wrong", phoneName: "Pixel 7")
        #expect(height(HistoryEntryScreen(state: s, actions: HistoryEntryActions())) > 0)
    }

    @Test func everyStepOfTheExportRenders() {
        var p = AuditExportAnswer(count: 40, more: true, uptoSeq: 90, uptoHash: "AA==")
        p.oldestAt = "2026-10-01T10:00:00.000Z"
        p.newestAt = "2026-10-08T10:00:00.000Z"
        var pin = ExportPin(preview: p, format: .csv)
        pin.error = .backoff
        pin.retryUntil = Date().addingTimeInterval(30)
        var wrong = ExportPin(preview: p, format: .json)
        wrong.error = .badPin
        let save = ExportSave(fileName: "vettid-history-20261008-140312.csv", format: .csv, requested: true)
        let file = ExportFile(bytes: Data("seq\r\n".utf8), name: save.fileName, format: .csv)
        let steps: [ExportStep] = [
            .closed, .previewing, .confirm(p, format: nil), .confirm(p, format: .json), .nothingToExport, .refused(.alarm), .refused(.oldVault),
            .pin(pin), .pin(wrong), .reading(done: 10, total: 40), .save(save), .done(written: 38, authorised: 40),
            .failed(.ownerCheckRequired), .failed(nil, saveFailed: true), .failed(.network),
        ]
        for step in steps where step != .closed {
            #expect(height(HistoryExportScreen(step: step, words: "All of your history", file: file, actions: HistoryExportActions())) > 0, "\(step)")
        }
        #expect(ExportDocument.contentType(.csv) == .commaSeparatedText && ExportDocument.contentType(.json) == .json)
        #expect(ExportDocument(file).bytes == file.bytes)
    }

    @Test func theRoutesRenderOverTheirRepositories() {
        let log = FakeAuditLog(FakeAuditLog.chain(3))
        let repo = HistoryManager { log }
        #expect(height(HistoryRoute(history: repo, export: HistoryExportManager { log }, chrome: chrome, host: HistoryHost())) > 0)
        #expect(height(HistoryRoute(history: repo, export: HistoryExportManager { log }, connectionID: "c1", chrome: nil, host: HistoryHost())) > 0)
        #expect(height(HistoryEntryRoute(2, history: repo, host: HistoryHost())) > 0)
    }

    /// The view's height laid out on an iPhone's screen, as the shell's render tests measure it.
    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.dark)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}

// swiftlint:enable line_length
#endif
