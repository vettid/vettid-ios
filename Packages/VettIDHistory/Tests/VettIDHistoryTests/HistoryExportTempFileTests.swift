import Foundation
import Testing
@testable import VettIDHistory

/// The export's temporary file (IOS-PLAN §4 "Save to Files"): made in a directory of its own with complete file
/// protection, the bytes unchanged, removed with its directory, and swept when a killed app left one. (Writing with complete
/// protection is refused on macOS, so those tests run in `HistoryExportPickerTests` on the simulator.)
@Suite struct HistoryExportTempFileTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func entries(_ root: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] }

    private func file(_ name: String = "vettid-history-20261008-140312.csv", _ text: String = "seq\r\n1\r\n") -> ExportFile {
        ExportFile(bytes: Data(text.utf8), name: name, format: .csv)
    }

    @Test func aFileThatCannotBeWrittenLeavesNoDirectory() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // A name with a missing sub-directory cannot be written.
        #expect(throws: (any Error).self) { try HistoryExportTempFile.write(file("missing/x.csv"), in: root) }
        #expect(entries(root).isEmpty)
    }

    @Test func leftoversOfAKilledAppAreRemovedAndOtherFilesAreNot() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(HistoryExportLeftovers.remove(in: root) == 0)
        for n in ["a", "b"] {
            let dir = root.appendingPathComponent(HistoryExportLeftovers.prefix + n, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("f.csv"))
        }
        try Data().write(to: root.appendingPathComponent("other.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("vettid-proof-keep"), withIntermediateDirectories: true)
        #expect(HistoryExportLeftovers.remove(in: root) == 2)
        #expect(entries(root).sorted() == ["other.txt", "vettid-proof-keep"])
        #expect(HistoryExportLeftovers.remove(in: root.appendingPathComponent("missing")) == 0)
    }
}
