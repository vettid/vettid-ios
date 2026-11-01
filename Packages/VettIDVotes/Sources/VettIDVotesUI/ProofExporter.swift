#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VettIDVotes

/// The vault's evidence of a vote as a file for the system's document picker (owner decision, 2026-11-01: the file exporter;
/// IOS-PLAN §4.16 names the share sheet). SwiftUI's `fileExporter` writes its document to the app's `tmp/` with the default
/// file protection and leaves it there after a save and after a cancel (checked on the simulator), so the file is made here
/// instead: in a directory of its own with complete file protection, handed to
/// `UIDocumentPickerViewController(forExporting:asCopy: true)`, and removed on every path (a pick, a cancel, a failure, the
/// screen leaving, the next file). Nothing of it is logged.
struct ProofTempFile {
    static let prefix = "vettid-proof-"

    let directory: URL
    let url: URL

    /// Writes [file]'s bytes, unchanged, under its name in a new directory; throws when it could not be written.
    static func write(_ file: ProofFile, in root: URL = FileManager.default.temporaryDirectory) throws -> ProofTempFile {
        let directory = root.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
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
        return ProofTempFile(directory: directory, url: url)
    }

    /// Removes the file and its directory (best effort).
    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// Proof directories left in [root] (by an app that was killed while the picker was up): removed.
    @discardableResult
    static func removeLeftovers(in root: URL = FileManager.default.temporaryDirectory) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let mine = names.filter { $0.hasPrefix(prefix) }
        for n in mine { try? FileManager.default.removeItem(at: root.appendingPathComponent(n)) }
        return mine.count
    }
}

/// Presents the document picker for the evidence while [file] is set, and answers once: saved (true), or cancelled (false);
/// a file that could not be made is [onFailed]. The temporary file goes on every path.
struct ProofExporter: UIViewControllerRepresentable {
    let file: ProofFile?
    let onAnswered: @MainActor (Bool) -> Void
    let onFailed: @MainActor () -> Void

    func makeCoordinator() -> ProofExportCoordinator { ProofExportCoordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.isUserInteractionEnabled = false
        host.view.isAccessibilityElement = false
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let c = context.coordinator
        c.onAnswered = onAnswered
        c.onFailed = onFailed
        c.update(file, host: host)
    }

    static func dismantleUIViewController(_ host: UIViewController, coordinator: ProofExportCoordinator) {
        coordinator.leave()
    }
}

@MainActor
final class ProofExportCoordinator: NSObject, UIDocumentPickerDelegate {
    var onAnswered: @MainActor (Bool) -> Void = { _ in }
    var onFailed: @MainActor () -> Void = {}
    /// The temporary file while the picker is up.
    private(set) var temp: ProofTempFile?
    private weak var picker: UIDocumentPickerViewController?
    /// The directory the files are made in (tests set it).
    var root = FileManager.default.temporaryDirectory

    /// [file] set: the picker opens (once for this file); nil: whatever is up closes.
    func update(_ file: ProofFile?, host: UIViewController) {
        guard let file else {
            close()
            return
        }
        guard temp == nil else { return }
        do {
            let t = try ProofTempFile.write(file, in: root)
            temp = t
            let picker = UIDocumentPickerViewController(forExporting: [t.url], asCopy: true)
            picker.delegate = self
            picker.shouldShowFileExtensions = true
            self.picker = picker
            // After the update that asked for it: the host is on screen by then.
            DispatchQueue.main.async { [weak host] in host?.present(picker, animated: true) }
        } catch {
            onFailed()
        }
    }

    /// The picker is gone without an answer (the screen left, or the file was taken away): the file goes.
    func close() {
        picker?.dismiss(animated: false)
        picker = nil
        removeTemp()
    }

    func leave() { close() }

    private func removeTemp() {
        temp?.remove()
        temp = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        removeTemp()
        picker = nil
        onAnswered(true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        removeTemp()
        picker = nil
        onAnswered(false)
    }
}
#endif
