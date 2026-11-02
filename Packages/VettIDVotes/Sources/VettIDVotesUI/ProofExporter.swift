#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VettIDVotes

/// The vault's evidence of a vote as a file for the system's document picker (owner decision, 2026-11-01;
/// IOS-PLAN §4.16 (0.1.54)). SwiftUI's `fileExporter` writes its document to the app's `tmp/` with the default
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
final class ProofExportCoordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    var onAnswered: @MainActor (Bool) -> Void = { _ in }
    var onFailed: @MainActor () -> Void = {}
    /// The temporary file while the picker is up.
    private(set) var temp: ProofTempFile?
    /// Held while the file is, so that it is not released before it is presented.
    private var picker: UIDocumentPickerViewController?
    /// The directory the files are made in (tests set it).
    var root = FileManager.default.temporaryDirectory

    /// [file] set: the picker opens (once for this file); nil: whatever is up closes. A picker that cannot be presented (no
    /// window, another presentation still under way after a few tries, or refused by UIKit) is told as a failure, and its
    /// file goes.
    func update(_ file: ProofFile?, host: UIViewController) {
        guard let file else {
            close()
            return
        }
        guard temp == nil else { return }
        let t: ProofTempFile
        do {
            t = try ProofTempFile.write(file, in: root)
        } catch {
            fail()
            return
        }
        temp = t
        let picker = UIDocumentPickerViewController(forExporting: [t.url], asCopy: true)
        picker.delegate = self
        picker.shouldShowFileExtensions = true
        // A swipe down that dismisses the picker counts as a cancel, whether or not the picker reports one itself.
        picker.presentationController?.delegate = self
        self.picker = picker
        // After the update that asked for it: the host is on screen by then.
        DispatchQueue.main.async { [weak self, weak host] in
            self?.present(picker, for: t, from: host, triesLeft: Self.presentTries)
        }
    }

    /// How many times a presentation is tried while another one (an alert closing, say) is still under way.
    static let presentTries = 4
    /// The wait between those tries (tests shorten it).
    var retryDelay: TimeInterval = 0.35
    /// Whether a presentation from a controller would be refused now (tests replace it).
    var busy: @MainActor (_ presenter: UIViewController) -> Bool = { ProofExportCoordinator.isBusy($0) }
    /// The presentation itself (tests replace it).
    var presentPicker: @MainActor (_ presenter: UIViewController, _ picker: UIViewController) -> Void = {
        $0.present($1, animated: true)
    }

    /// Presents [picker] if it and its file are still current. While another presentation is under way it waits and tries
    /// again; when it cannot present at all, or UIKit does not take the presentation, the file goes and the failure is told.
    private func present(_ picker: UIDocumentPickerViewController, for t: ProofTempFile, from host: UIViewController?, triesLeft: Int) {
        guard self.picker === picker, temp?.url == t.url else { return }
        guard let presenter = host.map(Self.topmost), presenter.viewIfLoaded?.window != nil else {
            fail()
            return
        }
        if busy(presenter) {
            guard triesLeft > 1 else {
                fail()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self, weak host] in
                self?.present(picker, for: t, from: host, triesLeft: triesLeft - 1)
            }
            return
        }
        presentPicker(presenter, picker)
        // UIKit sets this at once when it takes a presentation; one it refuses only logs, and no delegate call would come.
        if picker.presentingViewController == nil { fail() }
    }

    /// The controller a presentation starts from: the topmost one already presented over [host]'s.
    static func topmost(_ host: UIViewController) -> UIViewController {
        var top = host
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    /// Whether a presentation from [presenter] would be refused now: something over it is still leaving, it is itself
    /// arriving or leaving, or a transition is running.
    static func isBusy(_ presenter: UIViewController) -> Bool {
        presenter.presentedViewController != nil || presenter.isBeingDismissed || presenter.isBeingPresented
            || presenter.transitionCoordinator != nil
    }

    /// The picker could not be opened: the file goes and the failure is told, after the update that asked for it.
    private func fail() {
        picker = nil
        removeTemp()
        DispatchQueue.main.async { [weak self] in self?.onFailed() }
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
        answer(true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        answer(false)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        answer(false)
    }

    /// The member's answer, told once for the picker that is up: its file goes first.
    private func answer(_ saved: Bool) {
        guard picker != nil else { return }
        removeTemp()
        picker = nil
        onAnswered(saved)
    }
}
#endif
