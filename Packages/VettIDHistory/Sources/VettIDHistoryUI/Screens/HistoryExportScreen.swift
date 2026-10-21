#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VettIDData
import VettIDHistory
import VettIDUI
import VettIDVault

/// What the export's steps can ask for. Mirrors vettid-android `HistoryExportActions`.
public struct HistoryExportActions {
    public var onFormat: @MainActor (ExportFormat) -> Void = { _ in }
    public var onContinue: @MainActor () -> Void = {}
    /// The PIN, taken from the keypad as the request is sent (IOS-PLAN §6.5).
    public var onSubmitPin: @MainActor (String) -> Void = { _ in }
    /// "Save to Files" opened, or opened again.
    public var onSave: @MainActor () -> Void = {}
    /// The picker's answer: saved, or dismissed.
    public var onSaved: @MainActor (Bool) -> Void = { _ in }
    public var onSaveFailed: @MainActor () -> Void = {}
    public var onClose: @MainActor () -> Void = {}
    /// The credential alarm's screen (an open alarm refuses the export).
    public var onOpenAlarm: @MainActor () -> Void = {}
    /// The daily check (`owner_check_required`).
    public var onOwnerCheck: @MainActor () -> Void = {}

    public init() {}
}

/// The History export over the History screen (ANDROID-PLAN §4 History "Export"; IOS-PLAN §4: "Save to Files"), one step
/// at a time, full screen: the confirm step with the count, the range, the filters in words, the format and the
/// unencrypted notice; the vault PIN on the in-app keypad; reading; "Save to Files"; done; or why it cannot. [words] is
/// the list's filters in words. Mirrors vettid-android `HistoryExportContent`.
public struct HistoryExportScreen: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let step: ExportStep
    let words: String
    let actions: HistoryExportActions

    public init(step: ExportStep, words: String, actions: HistoryExportActions) {
        self.step = step
        self.words = words
        self.actions = actions
    }

    public var body: some View {
        Group {
            switch step {
            case .closed:
                EmptyView()
            case .previewing:
                ExportProgress(label: HistoryStrings.exportPreparing, fraction: nil, detail: nil, onCancel: actions.onClose)
            case .confirm(let preview, let format):
                ExportConfirm(preview: preview, format: format, words: words, actions: actions)
            case .nothingToExport:
                message(HistoryStrings.exportNothingTitle, HistoryStrings.exportNothing, .info)
            case .refused(.alarm):
                let open = (HistoryStrings.exportAlarmOpen, actions.onOpenAlarm)
                message(HistoryStrings.exportAlarmTitle, HistoryStrings.exportAlarm, .urgent, open)
            case .refused(.oldVault):
                message(HistoryStrings.exportOldVaultTitle, HistoryStrings.exportOldVault, .info)
            case .pin(let p):
                ExportPinStep(step: p, actions: actions)
            case .reading(let done, let total):
                ExportProgress(
                    label: HistoryStrings.exportReading(Int(total)), fraction: Double(done) / Double(max(total, 1)),
                    detail: HistoryStrings.exportReadingProgress(done, Int(total)), onCancel: actions.onClose
                )
            case .writing:
                ExportProgress(label: HistoryStrings.exportWriting, fraction: nil, detail: nil, onCancel: nil)
            case .save(let s):
                ExportSaveStep(save: s, actions: actions)
            case .done(let written, let authorised):
                ExportDone(written: written, authorised: authorised, onClose: actions.onClose)
            case .failed(let kind, let saveFailed):
                failed(kind, saveFailed: saveFailed)
            }
        }
        .accessibilityIdentifier("history_export")
    }

    @ViewBuilder private func failed(_ kind: FailureKind?, saveFailed: Bool) -> some View {
        let k = kind ?? .other
        let body = saveFailed ? HistoryStrings.exportSaveFailed : k.message(timeScale: timeScale)
        if kind == .ownerCheckRequired {
            message(HistoryStrings.exportFailedTitle, body, .warning, (HistoryStrings.exportOwnerCheck, actions.onOwnerCheck))
        } else {
            message(HistoryStrings.exportFailedTitle, body, .warning)
        }
    }

    private func message(
        _ title: String, _ body: String, _ kind: NoticeKind, _ extra: (String, @MainActor () -> Void)? = nil
    ) -> some View {
        FormScaffold(
            title: HistoryStrings.exportTitle, primaryLabel: HistoryStrings.exportClose, onPrimary: actions.onClose, onBack: actions.onClose
        ) {
            NoticeCard(kind, title: title, message: body) {
                if let extra { Button(extra.0, action: extra.1).accessibilityIdentifier("history_export_message_action") }
            }
            .accessibilityIdentifier("history_export_message")
        }
    }
}

/// The export's glyph over its steps.
private struct ExportGlyph: View {
    @Environment(\.vettIDColors) private var colors
    let symbol: String

    var body: some View {
        Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(colors.primary).padding(.top, Spacing.l)
            .accessibilityHidden(true)
    }
}

/// "Counting the entries…", "Preparing 40 entries…" with its progress, "Saving the file…".
private struct ExportProgress: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let fraction: Double?
    let detail: String?
    let onCancel: (@MainActor () -> Void)?

    var body: some View {
        FormScaffold(
            title: HistoryStrings.exportTitle, message: label, primaryLabel: nil,
            secondaryLabel: onCancel.map { _ in HistoryStrings.cancel },
            onPrimary: {}, onSecondary: onCancel ?? {}, onBack: onCancel, header: { ExportGlyph(symbol: "arrow.down.doc") }
        ) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .tint(colors.primary.color)
                        .accessibilityIdentifier("history_export_progress")
                } else {
                    ProgressView().tint(colors.primary.color)
                }
                if let detail { Text(detail).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant) }
            }
        }
    }
}

/// The confirm step: "40 entries, 1 Oct 2026 – 8 Oct 2026", what the list shows, the cap's notice, CSV or JSON (neither
/// preselected), and that the file is not encrypted.
private struct ExportConfirm: View {
    @Environment(\.vettIDColors) private var colors
    let preview: AuditExportAnswer
    let format: ExportFormat?
    let words: String
    let actions: HistoryExportActions

    var body: some View {
        FormScaffold(
            title: HistoryStrings.exportTitle, message: HistoryExportTexts.countAndRange(preview),
            primaryLabel: HistoryStrings.exportContinue, primaryEnabled: format != nil, secondaryLabel: HistoryStrings.cancel,
            onPrimary: actions.onContinue, onSecondary: actions.onClose,
            onBack: actions.onClose, header: { ExportGlyph(symbol: "arrow.down.doc") }
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text(HistoryStrings.exportFilters(words))
                    .vettIDFont(.bodyMedium)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .accessibilityIdentifier("history_export_filters")
                if preview.more {
                    let cap = HistoryStrings.exportCount(Int(HistoryExportManager.maxEntries))
                    NoticeCard(.info, title: cap, message: HistoryStrings.exportMore)
                        .accessibilityIdentifier("history_export_more")
                }
                Text(HistoryStrings.exportFormat).vettIDFont(.titleSmall)
                formatRow(.csv, HistoryStrings.exportCsv, HistoryStrings.exportCsvNote)
                formatRow(.json, HistoryStrings.exportJson, HistoryStrings.exportJsonNote)
                NoticeCard(.warning, title: HistoryStrings.exportUnencryptedTitle, message: HistoryStrings.exportUnencrypted)
                    .accessibilityIdentifier("history_export_unencrypted")
            }
        }
    }

    private func formatRow(_ f: ExportFormat, _ label: String, _ note: String) -> some View {
        Button { actions.onFormat(f) } label: {
            HStack(spacing: Spacing.m) {
                (format == f ? VettIDSymbol.radioChecked : VettIDSymbol.radioUnchecked).image
                    .foregroundStyle(format == f ? colors.primary : colors.onSurfaceVariant)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(label).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurface)
                    Text(note).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Spacing.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(format == f ? [.isSelected] : [])
        .accessibilityIdentifier("history_export_format_\(f.wire)")
    }
}

/// The vault PIN on the in-app keypad (IOS-PLAN §6.5), on its own step: "Wrong PIN", the backoff's countdown, or another
/// failure under it. The digits are dropped when the app leaves the foreground or the iPhone locks, and handed over once.
private struct ExportPinStep: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.vettIDTimeScale) private var timeScale
    let step: ExportPin
    let actions: HistoryExportActions
    @State private var pin = PinBuffer()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            FormScaffold(
                title: HistoryStrings.exportPinTitle, message: HistoryStrings.exportPinBody, primaryLabel: HistoryStrings.exportExport,
                primaryEnabled: step.canSend(pinLength: pin.count, now: context.date), busy: step.busy,
                secondaryLabel: HistoryStrings.cancel,
                onPrimary: { submit(context.date) }, onSecondary: actions.onClose, onBack: actions.onClose,
                header: { ExportGlyph(symbol: "lock") }
            ) {
                VStack(spacing: Spacing.m) {
                    Text(HistoryStrings.exportPinLabel).vettIDFont(.labelLarge).foregroundStyle(colors.onSurfaceVariant)
                    PinKeypad(buffer: pin)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(HistoryStrings.exportPinLabel)
                        .accessibilityIdentifier("history_export_pin")
                        .disabled(step.busy)
                    if let error = HistoryExportTexts.pinError(step, now: context.date, timeScale: timeScale) {
                        Text(error)
                            .vettIDFont(.bodySmall)
                            .foregroundStyle(colors.error)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("history_export_pin_error")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onDisappear { pin.clear() }
        .onChange(of: scenePhase) { _, now in
            // IOS-PLAN §6.3: typed secrets are dropped when the app leaves the foreground.
            if now == .background { pin.clear() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            pin.clear()
        }
    }

    private func submit(_ now: Date) {
        guard step.canSend(pinLength: pin.count, now: now) else { return }
        actions.onSubmitPin(pin.take())
    }
}

/// The file is ready: "Save to Files" opens by itself once, and again from the button; the suggested name below.
private struct ExportSaveStep: View {
    @Environment(\.vettIDColors) private var colors
    let save: ExportSave
    let actions: HistoryExportActions
    @State private var picking = false

    var body: some View {
        FormScaffold(
            title: HistoryStrings.exportSaveTitle, message: HistoryStrings.exportSaveBody, primaryLabel: HistoryStrings.exportSaveAgain,
            secondaryLabel: HistoryStrings.cancel, onPrimary: { open() }, onSecondary: { actions.onSaved(false) },
            onBack: { actions.onSaved(false) }, header: { ExportGlyph(symbol: "arrow.down.doc") }
        ) {
            Text(save.fileName).vettIDFont(.bodyMedium).accessibilityIdentifier("history_export_file_name")
        }
        .onAppear { if !save.requested { open() } }
        .sheet(isPresented: $picking) {
            ExportDocumentPicker(file: save.file) { result in
                picking = false
                switch result {
                case .saved: actions.onSaved(true)
                // ANDROID-PLAN §4 History "Export": a dismissed dialog discards the data.
                case .cancelled: actions.onSaved(false)
                case .failed: actions.onSaveFailed()
                }
            }
            .ignoresSafeArea()
        }
    }

    private func open() {
        actions.onSave()
        picking = true
    }
}

/// "History exported" with the count, or how many the retention removed meanwhile; the file is not encrypted.
private struct ExportDone: View {
    @Environment(\.vettIDColors) private var colors
    let written: Int
    let authorised: Int64
    let onClose: @MainActor () -> Void

    var body: some View {
        FormScaffold(
            title: HistoryStrings.exportDoneTitle, message: HistoryExportTexts.done(written: written, authorised: authorised),
            primaryLabel: HistoryStrings.exportClose, onPrimary: onClose, header: { ExportGlyph(symbol: "checkmark.circle") }
        ) {
            Text(HistoryStrings.exportDoneNote).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
        }
        .accessibilityIdentifier("history_export_done")
    }
}

/// "Save to Files" (IOS-PLAN §4): the system's document picker exporting a copy of the staged file to the place the
/// member chooses. Only the member chooses where it goes; nothing else is offered (no share sheet).
struct ExportDocumentPicker: UIViewControllerRepresentable {
    enum Result { case saved, cancelled, failed }

    let file: URL
    let onDone: @MainActor (Result) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDone: @MainActor (Result) -> Void

        init(onDone: @escaping @MainActor (Result) -> Void) { self.onDone = onDone }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            let result: Result = urls.isEmpty ? .failed : .saved
            MainActor.assumeIsolated { onDone(result) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            MainActor.assumeIsolated { onDone(.cancelled) }
        }
    }
}
#endif
