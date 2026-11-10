#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VettIDHistory

/// The History export as a file for the system's document picker (IOS-PLAN §4 "Save to Files"), made the way the vote
/// proof's is (IOS-PLAN §4.16): `UIDocumentPickerViewController(forExporting:asCopy: true)` over a file in a directory of
/// its own with complete file protection (``HistoryExportTempFile``), removed on every path (a pick, a cancel, a failure,
/// the screen leaving, the next file). Nothing of it is logged.

/// Presents the document picker for the export while [file] is set, and answers once: saved (true), or cancelled (false);
/// a file that could not be made is [onFailed]. The temporary file goes on every path.
struct HistoryExportPicker: UIViewControllerRepresentable {
    let file: ExportFile?
    let onAnswered: @MainActor (Bool) -> Void
    let onFailed: @MainActor () -> Void
    /// The picker was closed and its file removed without an answer (the app went to the background): the export stays, and
    /// "Choose where to save" again opens a new picker.
    let onClosed: @MainActor () -> Void

    func makeCoordinator() -> HistoryExportCoordinator { HistoryExportCoordinator() }

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
        c.onClosed = onClosed
        c.update(file, host: host)
    }

    static func dismantleUIViewController(_ host: UIViewController, coordinator: HistoryExportCoordinator) {
        coordinator.leave()
    }
}

@MainActor
final class HistoryExportCoordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    var onAnswered: @MainActor (Bool) -> Void = { _ in }
    var onFailed: @MainActor () -> Void = {}
    var onClosed: @MainActor () -> Void = {}
    /// The temporary file while the picker is up.
    private(set) var temp: HistoryExportTempFile?
    /// Held while the file is, so that it is not released before it is presented.
    private(set) var picker: UIDocumentPickerViewController?
    /// The directory the files are made in (tests set it).
    var root = FileManager.default.temporaryDirectory
    /// Whether the file now offered was already taken up: it is presented, answered or failed once, and only an update
    /// without a file starts the next one. Updates that still carry it after an answer or a failure (the failure is told
    /// after a hop) open nothing again.
    private var taken = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }

    /// [file] set: the picker opens (once for this file); nil: whatever is up closes. A picker that cannot be presented (no
    /// window, another presentation still under way after a few tries, or refused by UIKit) is told as a failure, and its
    /// file goes.
    func update(_ file: ExportFile?, host: UIViewController) {
        guard let file else {
            taken = false
            close()
            return
        }
        guard !taken else { return }
        taken = true
        let t: HistoryExportTempFile
        do {
            t = try HistoryExportTempFile.write(file, in: root)
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
    var busy: @MainActor (_ presenter: UIViewController) -> Bool = { HistoryExportCoordinator.isBusy($0) }
    /// The presentation itself (tests replace it).
    var presentPicker: @MainActor (_ presenter: UIViewController, _ picker: UIViewController) -> Void = {
        $0.present($1, animated: true)
    }

    /// Presents [picker] if it and its file are still current. While another presentation is under way it waits and tries
    /// again; when it cannot present at all, or UIKit does not take the presentation, the file goes and the failure is told.
    private func present(
        _ picker: UIDocumentPickerViewController, for t: HistoryExportTempFile, from host: UIViewController?, triesLeft: Int
    ) {
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
        // A picker already answered or closed meanwhile is not failed as well.
        if self.picker === picker, picker.presentingViewController == nil { fail() }
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
        picker?.presentingViewController?.dismiss(animated: false)
        picker = nil
        removeTemp()
    }

    func leave() {
        taken = false
        close()
    }

    private func removeTemp() {
        temp?.remove()
        temp = nil
    }

    // A picker that is not the current one (an earlier one answering late) changes nothing.
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard controller === picker else { return }
        answer(true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard controller === picker else { return }
        answer(false)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === picker else { return }
        answer(false)
    }

    /// The app went to the background: the picker closes and its file goes, but the export stays (``onClosed``), so the
    /// member taps "Choose where to save" again on return without a second export. The app lock does not close it
    /// (`vettIDLocked` closes nothing): the file stays through the lock window, unreadable while the phone is locked
    /// (complete protection), and the background close covers the rest.
    @objc func didEnterBackground() {
        guard picker != nil else { return }
        close()
        onClosed()
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
