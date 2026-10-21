import Foundation
import Observation
import VettIDData
import VettIDVault

/// Why History cannot export at all just now. Mirrors vettid-android `ExportRefusal`.
public enum ExportRefusal: Equatable, Sendable {
    /// A clone alarm is open (`credential_frozen` / `rotation_required`, §3.5.9).
    case alarm
    /// The vault release predates `audit.export` (VAULT-MESSAGING 0.22.0): `unsupported_type` or `bad_request`.
    case oldVault
}

/// The PIN step: the preview and the format chosen; [busy] while `audit.export` is on its way; [error] the last refusal
/// (`bad_pin`, or another failure); [retryUntil] the end of the PIN backoff (`retry_after`), during which Export stays
/// off. The PIN itself is never held here: it stays on the in-app keypad (IOS-PLAN §6.5) until it is sent.
public struct ExportPin: Equatable, Sendable {
    public var preview: AuditExportAnswer
    public var format: ExportFormat
    public var busy = false
    public var error: FailureKind?
    public var retryUntil: Date?

    public init(preview: AuditExportAnswer, format: ExportFormat) {
        self.preview = preview
        self.format = format
    }

    /// §11.3: the PIN is 6–32 ASCII digits.
    public static let pinLengths = 6...32

    /// Whether a PIN of [pinLength] digits may be sent at [now].
    public func canSend(pinLength: Int, now: Date) -> Bool {
        Self.pinLengths.contains(pinLength) && !busy && retryUntil.map { now >= $0 } ?? true
    }
}

/// The file waiting for "Save to Files": the suggested [fileName], the staged [file], [requested] once the picker opened.
public struct ExportSave: Equatable, Sendable {
    public var fileName: String
    public var format: ExportFormat
    public var file: URL
    public var requested = false
}

/// The steps of a History export (ANDROID-PLAN §4 History "Export"): preview → confirm → PIN → reading → writing →
/// "Save to Files" → done. Mirrors vettid-android `ExportStep`; on the iPhone the file is written before the picker opens
/// (``ExportDocuments``).
public enum ExportStep: Equatable, Sendable {
    /// No export under way.
    case closed
    /// The preview (`audit.export{dry_run}`) is on its way.
    case previewing
    /// The confirm step: the preview's count and range, the format chosen (none at first).
    case confirm(AuditExportAnswer, format: ExportFormat?)
    /// Nothing matches (a preview's `count` 0, or `not_found`: the entries are gone).
    case nothingToExport
    /// Export is refused for now; no Continue.
    case refused(ExportRefusal)
    case pin(ExportPin)
    /// The authorised entries are read (`audit.list` pages): [done] of [total].
    case reading(done: Int, total: Int64)
    /// The file is written where the picker copies it from.
    case writing
    case save(ExportSave)
    /// Saved: [written] entries of the [authorised] count (fewer when the retention dropped some meanwhile).
    case done(written: Int, authorised: Int64)
    /// A failure: the vault's (the daily check due, the network…), or [saveFailed] writing the file.
    case failed(FailureKind?, saveFailed: Bool = false)
}

/// What History knows when the member asks for an export: the list's filter and the names it shows (nil item names: the
/// app holds no item list yet). Mirrors vettid-android `ExportContext`.
public struct ExportContext: Equatable, Sendable {
    public var filter: AuditFilter
    public var connectionNames: [String: String]
    public var itemNames: [String: String]?

    public init(filter: AuditFilter, connectionNames: [String: String] = [:], itemNames: [String: String]? = nil) {
        self.filter = filter
        self.connectionNames = connectionNames
        self.itemNames = itemNames
    }
}

/// History export (VAULT-MESSAGING 0.22.0 §10.9, ANDROID-PLAN §4 History "Export"): exports what the list's filters show,
/// never more. The preview counts; the vault PIN, sealed to a UTK, authorises the export (`audit.export`); the entries
/// are then read with `audit.list` below the answer's `upto_seq` and held in memory only until the file is written for
/// "Save to Files" (``ExportDocuments``), which is deleted once the picker answers. Nothing is written without a
/// successful `audit.export` answer; cancelling or dismissing drops the entries and the file (the vault's
/// `audit.exported` entry stays). Mirrors vettid-android `HistoryExportViewModel`.
@MainActor
@Observable
public final class HistoryExportViewModel {
    @ObservationIgnored private let repo: any HistoryExportRepository
    @ObservationIgnored private let documents: any ExportDocuments
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private var context: ExportContext?
    @ObservationIgnored private var job: Task<Void, Never>?
    /// Bumped at every start and close: the answer to work started before is dropped.
    @ObservationIgnored private var generation = 0
    public private(set) var step = ExportStep.closed

    /// [now]: the clock (tests set it).
    public init(
        repo: any HistoryExportRepository, documents: any ExportDocuments = TemporaryExportDocuments(),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.repo = repo
        self.documents = documents
        self.now = now
    }

    deinit { work.cancelAll() }

    /// "Export…": the preview of what [context] shows.
    public func start(_ context: ExportContext) {
        drop()
        self.context = context
        step = .previewing
        let repo = repo
        let g = generation
        job = work.launch { [weak self] in
            do {
                let p = try await repo.preview(context.filter)
                self?.set(g, p.count <= 0 ? .nothingToExport : .confirm(p, format: nil))
            } catch {
                guard let self else { return }
                let f = error as? VaultFailure
                if let r = Self.refusal(f) {
                    set(g, .refused(r))
                } else if f?.kind == .notFound {
                    set(g, .nothingToExport)
                } else if !(error is CancellationError) {
                    set(g, .failed(failureKind(error)))
                }
            }
        }
    }

    private func set(_ g: Int, _ s: ExportStep) {
        if g == generation { step = s }
    }

    public func chooseFormat(_ f: ExportFormat) {
        if case .confirm(let p, _) = step { step = .confirm(p, format: f) }
    }

    /// Continue on the confirm step: the PIN step.
    public func confirm() {
        if case .confirm(let p, let f?) = step { step = .pin(ExportPin(preview: p, format: f)) }
    }

    /// Sends `audit.export` with [pin] (taken from the keypad), then reads the entries; nothing when the PIN step cannot
    /// send it yet.
    public func submitPin(_ pin: String) {
        guard case .pin(var s) = step, let c = context, s.canSend(pinLength: pin.count, now: now()), pin.allSatisfy(\.isASCIIDigit) else {
            return
        }
        s.busy = true
        s.error = nil
        step = .pin(s)
        let repo = repo
        let g = generation
        job = work.launch { [weak self] in
            let answer: AuditExportAnswer
            do {
                answer = try await repo.export(c.filter, format: s.format, uptoSeq: s.preview.uptoSeq, pin: pin)
            } catch {
                guard let self, !(error is CancellationError) else { return }
                set(g, pinRefused(s, error as? VaultFailure ?? VaultFailure(failureKind(error))))
                return
            }
            await self?.read(g, c, s.format, answer)
        }
    }

    private func pinRefused(_ s: ExportPin, _ e: VaultFailure) -> ExportStep {
        if Self.refusal(e) == .alarm { return .refused(.alarm) }
        switch e.kind {
        case .notFound: return .nothingToExport
        case .ownerCheckRequired: return .failed(e.kind)
        default:
            var n = s
            n.busy = false
            n.error = e.kind
            n.retryUntil = e.kind == .backoff && e.retryAfterSeconds > 0 ? now().addingTimeInterval(TimeInterval(e.retryAfterSeconds)) : nil
            return .pin(n)
        }
    }

    private func read(_ g: Int, _ c: ExportContext, _ format: ExportFormat, _ answer: AuditExportAnswer) async {
        set(g, .reading(done: 0, total: answer.count))
        do {
            // Device names are best effort: without them the file has the ids alone.
            let devices = try? await repo.devices()
            let records = try await repo.entries(c.filter, answer: answer) { [weak self] n in
                self?.set(g, .reading(done: n, total: answer.count))
            }
            guard g == generation else { return }
            let rows = records.map { row($0, c, devices) }
            let at = answer.answeredAt ?? now()
            let header = ExportHeader(exportedAt: at, filters: exportFilters(c), answer: answer)
            let bytes = HistoryFiles.bytes(format, header: header, rows: rows)
            let file = ExportFile(bytes: bytes, name: HistoryFiles.fileName(at, format), format: format)
            write(g, file, written: rows.count, authorised: answer.count)
        } catch {
            guard !(error is CancellationError) else { return }
            set(g, .failed(failureKind(error)))
        }
    }

    /// The file for the picker; the entries and the bytes are not kept.
    private func write(_ g: Int, _ f: ExportFile, written: Int, authorised: Int64) {
        set(g, .writing)
        do {
            let file = try documents.stage(f.bytes, fileName: f.name)
            guard g == generation else { return documents.discard(file) }
            pendingCounts = (written, authorised)
            step = .save(ExportSave(fileName: f.name, format: f.format, file: file))
        } catch {
            set(g, .failed(nil, saveFailed: true))
        }
    }

    @ObservationIgnored private var pendingCounts: (written: Int, authorised: Int64)?

    /// The screen opened "Save to Files" (so that a redraw does not open it again).
    public func saveRequested() {
        if case .save(var s) = step {
            s.requested = true
            step = .save(s)
        }
    }

    /// The picker's answer: [saved] true once the file was copied where the member chose, false when it was dismissed
    /// (the export is dropped). The staged file is deleted either way.
    public func saved(_ saved: Bool) {
        guard case .save(let s) = step else { return }
        documents.discard(s.file)
        guard saved, let counts = pendingCounts else { return close() }
        pendingCounts = nil
        step = .done(written: counts.written, authorised: counts.authorised)
    }

    /// The picker could not copy the file: "The file could not be saved".
    public func saveFailed() {
        guard case .save(let s) = step else { return }
        documents.discard(s.file)
        pendingCounts = nil
        step = .failed(nil, saveFailed: true)
    }

    /// Cancel, Back or Close at any step: the entries read so far and the file are dropped.
    public func close() {
        drop()
        step = .closed
    }

    private func drop() {
        generation += 1
        job?.cancel()
        job = nil
        pendingCounts = nil
        if case .save(let s) = step { documents.discard(s.file) }
        // Anything an export that never ended left behind.
        documents.discardAll()
    }

    private func row(_ r: AuditRecord, _ c: ExportContext, _ devices: HistoryDevices?) -> ExportRow {
        let connection = r.entry.connectionID.map { c.connectionNames[$0] ?? HistoryStrings.connectionRemoved }
        let itemID = AuditKinds.itemOf(r.kind, r.entry.ref)
        let item = itemID.flatMap { id in c.itemNames.map { $0[id] ?? HistoryStrings.itemDeleted } }
        let names = EntryNames(
            connection: r.entry.connectionID.flatMap { c.connectionNames[$0] }, device: devices?.device(r.entry.deviceID)?.rowName,
            item: itemID.flatMap { c.itemNames?[$0] }
        )
        return ExportRow(
            record: r, label: HistoryText.title(r.kind, r.entry.ref, names: names), connectionName: connection,
            deviceName: HistoryText.deviceName(r.entry.deviceID, devices), itemName: item
        )
    }

    private func exportFilters(_ c: ExportContext) -> ExportFilters {
        ExportFilters(c.filter, connectionName: c.filter.connectionID.map { c.connectionNames[$0] ?? HistoryStrings.connectionRemoved })
    }

    static func refusal(_ e: VaultFailure?) -> ExportRefusal? {
        guard let e else { return nil }
        if e.kind == .credentialFrozen || e.kind == .rotationRequired { return .alarm }
        if e.kind == .notSupported || e.code == "unsupported_type" || e.code == "bad_request" { return .oldVault }
        return nil
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}

/// A file's bytes, its name and its format, before it is staged.
private struct ExportFile {
    var bytes: [UInt8]
    var name: String
    var format: ExportFormat
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
