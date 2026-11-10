import Foundation

/// The export's temporary directories (IOS-PLAN §4 "Save to Files"; the proof's pattern, IOS-PLAN §4.16). SwiftUI's
/// `fileExporter` writes its document to the app's `tmp/` with the default file protection and leaves it there after a
/// save and after a cancel, so each export's file is made in a directory of its own, named with [prefix], with complete
/// file protection, and removed on every path. One can be left only by an app that was killed while the system's document
/// picker was up; [remove] clears those, at launch. Nothing of it is read back or logged.
public enum HistoryExportLeftovers {
    public static let prefix = "vettid-history-export-"

    /// Removes the export directories left in [root] (best effort) and returns how many there were. Nothing else in
    /// [root] is touched.
    @discardableResult
    public static func remove(in root: URL = FileManager.default.temporaryDirectory) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let mine = names.filter { $0.hasPrefix(prefix) }
        for n in mine { try? FileManager.default.removeItem(at: root.appendingPathComponent(n)) }
        return mine.count
    }
}

/// The export's bytes as a file for the system's document picker, in a directory of its own.
public struct HistoryExportTempFile: Equatable, Sendable {
    public let directory: URL
    public let url: URL

    /// Writes [file]'s bytes, unchanged, under its name in a new directory; throws when it could not be written.
    public static func write(_ file: ExportFile, in root: URL = FileManager.default.temporaryDirectory) throws -> HistoryExportTempFile {
        let directory = root.appendingPathComponent(HistoryExportLeftovers.prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.protectionKey: FileProtectionType.complete]
        )
        let url = directory.appendingPathComponent(file.name)
        do {
            try file.bytes.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return HistoryExportTempFile(directory: directory, url: url)
    }

    /// Removes the file and its directory (best effort).
    public func remove() { try? FileManager.default.removeItem(at: directory) }
}
