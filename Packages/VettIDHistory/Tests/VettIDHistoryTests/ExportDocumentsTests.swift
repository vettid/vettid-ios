import Foundation
import Testing
@testable import VettIDHistory

/// The export's file waits in a folder of its own under the temporary directory, excluded from backups, and is deleted
/// with its folder; only the store's own folders are ever deleted.
@Suite struct ExportDocumentsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-export-test-\(UUID().uuidString)", isDirectory: true)

    @Test func aStagedFileIsWrittenAndDeletedWithItsFolder() throws {
        let docs = TemporaryExportDocuments(root: root)
        defer { docs.discardAll() }
        let url = try docs.stage(Array("seq,time\r\n".utf8), fileName: "vettid-history-20261008-140312.csv")
        #expect(url.lastPathComponent == "vettid-history-20261008-140312.csv")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(try Data(contentsOf: url) == Data("seq,time\r\n".utf8))
        let values = try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        // Two exports never share a folder.
        let other = try docs.stage([1], fileName: "vettid-history-20261008-140312.csv")
        #expect(other != url)
        docs.discard(url)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        docs.discardAll()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func onlyItsOwnFoldersAreDeleted() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let file = outside.appendingPathComponent("a.csv")
        try Data([1]).write(to: file)
        TemporaryExportDocuments(root: root).discard(file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
