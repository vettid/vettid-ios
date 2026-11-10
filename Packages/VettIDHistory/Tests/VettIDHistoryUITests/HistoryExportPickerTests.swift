#if os(iOS)
import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
import VettIDData
@testable import VettIDHistory
@testable import VettIDHistoryUI

/// The History export's document picker (IOS-PLAN §4 "Save to Files"): its temporary file is removed on every path, and
/// the outcomes the screen reports (saved, cancelled, failed) are the same as before. Mirrors the proof's tests
/// (``HistoryExportCoordinator`` is the proof's coordinator).
@MainActor
@Suite(.serialized) struct HistoryExportPickerTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-ui-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func entries(_ root: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] }

    private let file = ExportFile(bytes: Data("seq\r\n".utf8), name: "vettid-history-20261008-140312.csv", format: .csv)

    private func windowed(_ controller: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    @Test func theTemporaryFileIsTheBytesUnchangedUnderItsNameInADirectoryOfItsOwn() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = file
        let t = try HistoryExportTempFile.write(f, in: root)
        #expect(try Data(contentsOf: t.url) == f.bytes && t.url.lastPathComponent == f.name)
        #expect(entries(root).count == 1 && entries(root)[0].hasPrefix(HistoryExportLeftovers.prefix))
        #expect(t.url.deletingLastPathComponent() == t.directory)
        // Complete file protection where the system reports it (the file and its directory).
        for path in [t.url.path, t.directory.path] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let protection = attributes[.protectionKey] as? FileProtectionType { #expect(protection == .complete) }
        }
        t.remove()
        #expect(entries(root).isEmpty)
    }

    @Test func eachExportHasItsOwnDirectory() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try HistoryExportTempFile.write(file, in: root)
        let b = try HistoryExportTempFile.write(file, in: root)
        #expect(a.directory != b.directory && entries(root).count == 2)
    }

    @Test func theContentTypesAreCsvAndJson() {
        #expect(ExportContentType.of(.csv) == .commaSeparatedText && ExportContentType.of(.json) == .json)
        #expect(UTType(filenameExtension: (file.name as NSString).pathExtension) == ExportContentType.of(file.format))
        #expect(UTType(filenameExtension: ExportFormat.csv.fileExtension) == .commaSeparatedText)
        #expect(UTType(filenameExtension: ExportFormat.json.fileExtension) == .json)
    }

    /// The file exists while the picker is up and is removed on a save, a cancel, the screen leaving and the file taken away.
    @Test func theFileGoesAfterASaveACancelAndTheScreenLeaving() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = UIViewController()
        func run(_ end: (HistoryExportCoordinator, UIDocumentPickerViewController) -> Void) -> [Bool] {
            let c = HistoryExportCoordinator()
            c.root = root
            var answers: [Bool] = []
            c.onAnswered = { answers.append($0) }
            c.update(file, host: host)
            #expect(entries(root).count == 1, "the file exists while the picker is up")
            #expect((try? Data(contentsOf: c.temp?.url ?? root)) == file.bytes)
            end(c, c.picker ?? UIDocumentPickerViewController(forOpeningContentTypes: [.json]))
            #expect(entries(root).isEmpty, "removed")
            return answers
        }
        #expect(run { c, p in c.documentPicker(p, didPickDocumentsAt: [c.temp!.url]) } == [true])
        #expect(run { c, p in c.documentPickerWasCancelled(p) } == [false])
        #expect(run { c, _ in c.leave() }.isEmpty)
        #expect(run { c, _ in c.update(nil, host: host) }.isEmpty)
    }

    /// A swipe down is a cancel, told once.
    @Test func aSwipeDownIsACancelToldOnceAndTheFileGoes() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = HistoryExportCoordinator()
        c.root = root
        var answers: [Bool] = []
        c.onAnswered = { answers.append($0) }
        c.presentPicker = { _, _ in }
        let controller = try #require(windowed(UIViewController()).rootViewController)
        c.update(file, host: controller)
        let picker = try #require(c.picker)
        c.presentationControllerDidDismiss(UIPresentationController(presentedViewController: picker, presenting: controller))
        c.documentPickerWasCancelled(picker)
        #expect(entries(root).isEmpty && answers == [false])
    }

    /// An error: a file that cannot be written, and a picker that cannot be presented, are told as a failure once and leave
    /// nothing behind.
    @Test func theFileGoesAfterAnError() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = HistoryExportCoordinator()
        var failed = 0
        c.onFailed = { failed += 1 }
        c.root = root.appendingPathComponent("missing/deeper")
        c.update(file, host: UIViewController())
        try await Task.sleep(for: .seconds(0.1))
        #expect(failed == 1 && c.temp == nil)
        // No window: the file was made, then goes when the presentation fails.
        let d = HistoryExportCoordinator()
        d.root = root
        d.onFailed = { failed += 1 }
        d.update(file, host: UIViewController())
        #expect(entries(root).count == 1)
        try await Task.sleep(for: .seconds(0.1))
        #expect(entries(root).isEmpty && d.temp == nil && failed == 2)
    }

    /// The next export replaces the one before it: the same file offered again makes no second file, and a new offer after
    /// the file was taken away removes the earlier one first.
    @Test func theNextExportReplacesTheLastAndNeverLeavesTwo() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = UIViewController()
        let c = HistoryExportCoordinator()
        c.root = root
        c.update(file, host: host)
        c.update(file, host: host)
        #expect(entries(root).count == 1)
        c.update(nil, host: host)
        #expect(entries(root).isEmpty)
        c.update(file, host: host)
        #expect(entries(root).count == 1)
        c.leave()
        #expect(entries(root).isEmpty)
    }

    /// A cover that closes the picker (`closesWhenCovered` sets the file to nil) removes the file and tells nothing.
    @Test func aCoverClosingThePickerRemovesTheFileAndTellsNothing() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = UIViewController()
        let c = HistoryExportCoordinator()
        c.root = root
        var answers: [Bool] = []
        var failed = 0
        c.onAnswered = { answers.append($0) }
        c.onFailed = { failed += 1 }
        c.update(file, host: host)
        c.update(nil, host: host)
        #expect(entries(root).isEmpty && answers.isEmpty && failed == 0)
    }

    /// Dismantling the picker's view (the screen leaving) removes the file.
    @Test func dismantlingThePickerRemovesTheFile() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = HistoryExportCoordinator()
        c.root = root
        let host = UIViewController()
        c.update(file, host: host)
        #expect(entries(root).count == 1)
        HistoryExportPicker.dismantleUIViewController(host, coordinator: c)
        #expect(entries(root).isEmpty)
    }

    /// After a failure or an answer, updates that still carry the same file (the failure is told after a hop, and SwiftUI
    /// may update in between) open nothing again: no second file, no second presentation, no second failure. The file
    /// taken away and offered again opens the picker again.
    @Test func aFileIsTakenUpOnceUntilItIsTakenAway() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = windowed(UIViewController())
        let controller = try #require(window.rootViewController)
        let c = HistoryExportCoordinator()
        c.root = root
        var presented = 0, failed = 0
        var answers: [Bool] = []
        c.presentPicker = { _, _ in presented += 1 }
        c.onFailed = { failed += 1 }
        c.onAnswered = { answers.append($0) }
        // The test's presentation takes nothing, so the backstop fails it; the file is still offered meanwhile.
        c.update(file, host: controller)
        try await Task.sleep(for: .seconds(0.1))
        #expect(presented == 1 && failed == 1 && entries(root).isEmpty)
        c.update(file, host: controller)
        c.update(file, host: controller)
        try await Task.sleep(for: .seconds(0.1))
        #expect(presented == 1 && failed == 1 && entries(root).isEmpty, "the same file is not taken up again")
        // Taken away, then offered again: a new picker, and after its answer the same file opens nothing more.
        c.update(nil, host: controller)
        c.presentPicker = { _, _ in
            presented += 1
            if let current = c.picker { c.documentPickerWasCancelled(current) }
        }
        c.update(file, host: controller)
        try await Task.sleep(for: .seconds(0.1))
        #expect(presented == 2 && answers == [false] && entries(root).isEmpty)
        c.update(file, host: controller)
        try await Task.sleep(for: .seconds(0.1))
        #expect(presented == 2 && answers == [false] && failed == 1 && entries(root).isEmpty)
        c.leave()
    }

    /// A picker that cannot be presented (no window) leaves no file and is told as a failure, once.
    @Test func aPickerThatCannotBePresentedRemovesTheFileAndIsTold() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = HistoryExportCoordinator()
        c.root = root
        var failed = 0
        var answered: [Bool] = []
        c.onFailed = { failed += 1 }
        c.onAnswered = { answered.append($0) }
        c.update(file, host: UIViewController())
        #expect(entries(root).count == 1 && failed == 0)
        try await Task.sleep(for: .seconds(0.1))
        #expect(entries(root).isEmpty && c.temp == nil && failed == 1 && answered.isEmpty)
    }

    /// A close between the update and the hop opens no picker for a deleted file and tells nothing.
    @Test func aCloseBeforeThePresentationOpensNothing() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = HistoryExportCoordinator()
        c.root = root
        var failed = 0
        var presented = 0
        c.onFailed = { failed += 1 }
        c.presentPicker = { _, _ in presented += 1 }
        let window = windowed(UIViewController())
        let controller = try #require(window.rootViewController)
        c.update(file, host: controller)
        c.leave()
        try await Task.sleep(for: .seconds(0.2))
        #expect(entries(root).isEmpty && failed == 0 && presented == 0)
    }

    /// With the host on screen and nothing over it, the picker is presented from the host, once; a presentation UIKit does
    /// not take (it only logs one made while another is under way) removes the file and is told, once.
    @Test func aPresentationUIKitDidNotTakeRemovesTheFileAndIsTold() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = HistoryExportCoordinator()
        c.root = root
        var failed = 0
        var answered: [Bool] = []
        var presenters: [UIViewController] = []
        c.onFailed = { failed += 1 }
        c.onAnswered = { answered.append($0) }
        c.presentPicker = { presenter, picker in
            presenters.append(presenter)
            #expect(picker is UIDocumentPickerViewController)
        }
        let window = windowed(UIViewController())
        let controller = try #require(window.rootViewController)
        c.update(file, host: controller)
        #expect(entries(root).count == 1)
        try await Task.sleep(for: .seconds(0.2))
        #expect(presenters.count == 1 && presenters.first === controller)
        #expect(entries(root).isEmpty && c.temp == nil && failed == 1 && answered.isEmpty)
    }

    /// While another presentation is under way the picker waits and is presented once it is free; busy past every try, the
    /// file goes and the failure is told once, with nothing presented.
    @Test func aBusyHostIsWaitedForThenGivenUpOn() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = windowed(UIViewController())
        let controller = try #require(window.rootViewController)
        struct Outcome { var asked = 0, presented = 0, failed = 0, files = 0 }
        func run(busyFor: Int) async throws -> Outcome {
            let c = HistoryExportCoordinator()
            c.root = root
            c.retryDelay = 0.01
            var o = Outcome()
            c.busy = { _ in o.asked += 1; return o.asked <= busyFor }
            c.presentPicker = { _, _ in o.presented += 1 }
            c.onFailed = { o.failed += 1 }
            c.update(file, host: controller)
            try await Task.sleep(for: .seconds(0.4))
            o.files = entries(root).count
            c.leave()
            return o
        }
        let tries = HistoryExportCoordinator.presentTries
        // Free on the last try: presented once (the test's presentation takes nothing, so the backstop then tells it).
        let late = try await run(busyFor: tries - 1)
        #expect(late.asked == tries && late.presented == 1 && late.failed == 1 && late.files == 0)
        // Busy on every try: never presented, told once, the file gone.
        let never = try await run(busyFor: .max)
        #expect(never.asked == tries && never.presented == 0 && never.failed == 1 && never.files == 0)
    }

    /// A close while the picker waits for a busy host ends the tries: nothing is presented or told.
    @Test func aCloseWhileWaitingEndsTheTries() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = windowed(UIViewController())
        let controller = try #require(window.rootViewController)
        let c = HistoryExportCoordinator()
        c.root = root
        c.retryDelay = 0.2
        var asked = 0, presented = 0, failed = 0
        c.busy = { _ in asked += 1; return true }
        c.presentPicker = { _, _ in presented += 1 }
        c.onFailed = { failed += 1 }
        c.update(file, host: controller)
        try await Task.sleep(for: .seconds(0.02))
        c.leave()
        try await Task.sleep(for: .seconds(0.4))
        #expect(asked == 1 && presented == 0 && failed == 0 && entries(root).isEmpty)
    }

    /// A host with nothing over it and no transition is free to present.
    @Test func aHostWithNothingOverItIsNotBusy() {
        let window = windowed(UIViewController())
        let controller = window.rootViewController!
        #expect(!HistoryExportCoordinator.isBusy(controller))
    }

    /// The presentation starts from the controller itself when nothing is presented over it (a modal over a test window needs a
    /// scene, which a unit test host does not give, so the chain is not built here).
    @Test func thePresentationStartsFromTheHostWhenNothingIsPresented() {
        let host = UIViewController()
        #expect(HistoryExportCoordinator.topmost(host) === host)
    }

    /// The app going to the background closes the picker and removes the file but ends nothing: no answer and no failure are
    /// told, only the close; with no picker up it tells nothing. "Save to Files" again opens a new picker with a new file.
    @Test func theBackgroundClosesThePickerButKeepsTheExport() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = HistoryExportCoordinator()
        c.root = root
        var answers: [Bool] = []
        var failed = 0
        var closed = 0
        c.onAnswered = { answers.append($0) }
        c.onFailed = { failed += 1 }
        c.onClosed = { closed += 1 }
        c.didEnterBackground()
        #expect(closed == 0, "nothing was up")
        let host = UIViewController()
        c.update(file, host: host)
        let first = try #require(c.temp)
        #expect(entries(root).count == 1)
        c.didEnterBackground()
        #expect(entries(root).isEmpty && c.temp == nil && c.picker == nil)
        #expect(closed == 1 && answers.isEmpty && failed == 0, "the export is not ended")
        c.didEnterBackground()
        #expect(closed == 1, "told once")
        // The screen sets the file to nil, then offers it again ("Save again"): a new picker and a new file.
        c.update(nil, host: host)
        c.update(file, host: host)
        let second = try #require(c.temp)
        #expect(entries(root).count == 1 && second.directory != first.directory && c.picker != nil)
        #expect(try Data(contentsOf: second.url) == file.bytes)
        c.leave()
        #expect(entries(root).isEmpty)
    }

    /// In the background nothing is written or presented: an offer there leaves no entry, makes no picker, and tells the screen
    /// the close (the export stays); an offer that turned background between the update and the presentation removes its file.
    /// Back in the foreground the same file opens again.
    @Test func nothingIsWrittenOrPresentedInTheBackground() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = windowed(UIViewController()).rootViewController ?? UIViewController()
        let c = HistoryExportCoordinator()
        c.root = root
        var closed = 0, failed = 0, answers = 0, presented = 0
        c.onClosed = { closed += 1 }
        c.onFailed = { failed += 1 }
        c.onAnswered = { _ in answers += 1 }
        c.presentPicker = { _, _ in presented += 1 }
        c.inBackground = { true }
        c.update(file, host: host)
        #expect(entries(root).isEmpty && c.picker == nil && c.temp == nil, "no file")
        try await Task.sleep(for: .seconds(0.1))
        #expect(closed == 1 && failed == 0 && answers == 0 && presented == 0)
        // The offer is not taken up: the next one, in the foreground, opens normally.
        c.inBackground = { false }
        c.update(file, host: host)
        #expect(entries(root).count == 1 && c.picker != nil)
        // Turned background before the presentation: the file goes, nothing is presented.
        c.inBackground = { true }
        try await Task.sleep(for: .seconds(0.2))
        #expect(entries(root).isEmpty && presented == 0 && closed == 2 && failed == 0)
        c.leave()
    }

    /// The phone locking ends the export, with or without a picker up: the file goes and the screen is told.
    @Test func aLockEndsTheExportWithOrWithoutAPicker() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = HistoryExportCoordinator()
        c.root = root
        var locked = 0, answers: [Bool] = []
        c.onLocked = { locked += 1 }
        c.onAnswered = { answers.append($0) }
        c.didLock()
        #expect(locked == 1, "a kept export (no picker) ends too")
        c.update(file, host: UIViewController())
        #expect(entries(root).count == 1)
        c.didLock()
        #expect(locked == 2 && entries(root).isEmpty && c.picker == nil && answers.isEmpty)
        c.update(nil, host: UIViewController())
    }

    /// The system's lock notification reaches the coordinator; a background close alone does not end the export.
    @Test func theLockNotificationIsWiredToTheCoordinator() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = HistoryExportCoordinator()
        c.root = root
        var locked = 0
        c.onLocked = { locked += 1 }
        c.update(file, host: UIViewController())
        c.didEnterBackground()
        #expect(locked == 0, "no lock, the export stays")
        NotificationCenter.default.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        #expect(locked == 1)
    }

    /// The notification itself reaches the coordinator.
    @Test func theBackgroundNotificationIsWiredToTheCoordinator() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = HistoryExportCoordinator()
        c.root = root
        var closed = 0
        c.onClosed = { closed += 1 }
        c.update(file, host: UIViewController())
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(closed == 1 && entries(root).isEmpty)
    }

    /// An earlier picker answering late (or a stranger) changes nothing: the current picker and its file stay.
    @Test func aStalePickersCallbacksChangeNothing() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = HistoryExportCoordinator()
        c.root = root
        var answers: [Bool] = []
        c.onAnswered = { answers.append($0) }
        let host = UIViewController()
        c.update(file, host: host)
        let stale = UIDocumentPickerViewController(forOpeningContentTypes: [.json])
        c.documentPicker(stale, didPickDocumentsAt: [])
        c.documentPickerWasCancelled(stale)
        c.presentationControllerDidDismiss(UIPresentationController(presentedViewController: stale, presenting: host))
        #expect(answers.isEmpty && entries(root).count == 1 && c.picker != nil && c.temp != nil)
        c.documentPickerWasCancelled(try #require(c.picker))
        #expect(answers == [false] && entries(root).isEmpty)
    }
}
#endif
