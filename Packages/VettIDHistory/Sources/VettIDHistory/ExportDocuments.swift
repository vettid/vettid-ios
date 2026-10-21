import Foundation

/// Where a History export's file waits while the member picks where it goes (IOS-PLAN §4: "Save to Files" in place of
/// Android's "Save to…"). The iPhone's document picker exports a file that exists, so the bytes are written to a folder
/// of their own in the app's temporary directory (never backed up), with complete file protection, handed to the picker
/// as a copy, and deleted as soon as the picker answers or the export closes; a folder left by an export that never
/// ended (the app was stopped) is deleted at the next export. Never a copy in Documents, the photo library or the
/// clipboard, never a share sheet. (Chosen; not in the spec: ANDROID-PLAN §4 History writes straight to the chosen
/// document, which the iPhone's picker does not offer.) Mirrors vettid-android `ExportDocuments`.
public protocol ExportDocuments: Sendable {
    /// Writes [bytes] to a new file named [fileName]; its URL.
    func stage(_ bytes: [UInt8], fileName: String) throws -> URL

    /// Deletes a staged file and its folder (best effort).
    func discard(_ url: URL)

    /// Deletes every staged file (best effort).
    func discardAll()
}

/// ``ExportDocuments`` in a folder of the temporary directory, one subfolder per export.
public struct TemporaryExportDocuments: ExportDocuments {
    let root: URL

    public init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("history-export", isDirectory: true)) {
        self.root = root
    }

    public func stage(_ bytes: [UInt8], fileName: String) throws -> URL {
        var folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        var file = folder.appendingPathComponent(fileName, isDirectory: false)
        do {
            try Data(bytes).write(to: file, options: [.withoutOverwriting, .completeFileProtection])
            try? file.setResourceValues(values)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return file
    }

    public func discard(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        // Only a folder of this store's own.
        guard folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    public func discardAll() { try? FileManager.default.removeItem(at: root) }
}
