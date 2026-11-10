#if os(iOS)
import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
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
            end(c, UIDocumentPickerViewController(forOpeningContentTypes: [.json]))
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
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json])
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
}
#endif
