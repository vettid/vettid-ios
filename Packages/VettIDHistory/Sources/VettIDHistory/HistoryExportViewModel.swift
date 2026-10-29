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

/// The file waiting for "Save to Files": the suggested [fileName], its [format], [requested] once the exporter opened.
public struct ExportSave: Equatable, Sendable {
    public var fileName: String
    public var format: ExportFormat
    public var requested = false

    public init(fileName: String, format: ExportFormat, requested: Bool = false) {
        self.fileName = fileName
        self.format = format
        self.requested = requested
    }
}

/// The export's file, in memory only (IOS-PLAN §4 "Save to Files"; ANDROID-PLAN §4 History "Export" step 4: no copy in
/// the cache): its bytes, its suggested name and its format, handed to the system's exporter, which writes it where the
/// member chooses.
public struct ExportFile: Equatable, Sendable {
    public var bytes: Data
    public var name: String
    public var format: ExportFormat
}

/// The steps of a History export (ANDROID-PLAN §4 History "Export"): preview → confirm → PIN → reading → "Save to Files"
/// → done. Mirrors vettid-android `ExportStep`; on the iPhone the system's exporter writes the file itself, so there is no
/// writing step of the app's.
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
    case save(ExportSave)
    /// Saved: [written] entries of the [authorised] count (fewer when the retention dropped some meanwhile).
    case done(written: Int, authorised: Int64)
    /// A failure: the vault's (the daily check due, the network…), or [saveFailed] the exporter could not write the file.
    case failed(FailureKind?, saveFailed: Bool = false)
}

/// What History knows when the member asks for an export: the list's filter and the names it shows (connections by id,
/// "" before their names arrived; nil item names: the app holds no item list yet). Mirrors vettid-android
/// `ExportContext`.
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
/// are then read with `audit.list` below the answer's `upto_seq` and held in memory only: the file's bytes
/// (``exportFile``) exist only while the step is "Save to Files", and the system's exporter writes them only to the
/// place the member chooses; the app writes no file of its own. Nothing is written without a successful `audit.export`
/// answer; cancelling or dismissing drops the entries and the bytes (the vault's `audit.exported` entry stays). Mirrors
/// vettid-android `HistoryExportViewModel`.
@MainActor
@Observable
public final class HistoryExportViewModel {
    @ObservationIgnored private let repo: any HistoryExportRepository
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private var context: ExportContext?
    @ObservationIgnored private var job: Task<Void, Never>?
    /// Bumped at every start and close: the answer to work started before is dropped.
    @ObservationIgnored private var generation = 0
    public private(set) var step = ExportStep.closed

    /// [now]: the clock (tests set it).
    public init(repo: any HistoryExportRepository, now: @escaping @MainActor () -> Date = { Date() }) {
        self.repo = repo
        self.now = now
    }

    /// The file "Save to Files" writes: only while the step is ``ExportStep/save(_:)``, else nil.
    public var exportFile: ExportFile? {
        if case .save = step { return pending?.file }
        return nil
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
            let bytes = Data(HistoryFiles.bytes(format, header: header, rows: rows))
            let file = ExportFile(bytes: bytes, name: HistoryFiles.fileName(at, format), format: format)
            pending = Pending(file: file, written: rows.count, authorised: answer.count)
            step = .save(ExportSave(fileName: file.name, format: format))
        } catch {
            guard !(error is CancellationError) else { return }
            set(g, .failed(failureKind(error)))
        }
    }

    /// The file and its counts, from a successful read until the exporter answers or the export closes.
    @ObservationIgnored private var pending: Pending?

    private struct Pending {
        var file: ExportFile
        var written: Int
        var authorised: Int64
    }

    /// The screen opened "Save to Files" (so that a redraw does not open it again).
    public func saveRequested() {
        if case .save(var s) = step {
            s.requested = true
            step = .save(s)
        }
    }

    /// The exporter's answer: [saved] true once the file was written where the member chose; false when it was cancelled
    /// or dismissed: the export is dropped (ANDROID-PLAN §4 History "Export": a dismissed dialog discards the data). The
    /// bytes are dropped either way.
    public func saved(_ saved: Bool) {
        guard case .save = step else { return }
        guard saved, let p = pending else { return close() }
        pending = nil
        step = .done(written: p.written, authorised: p.authorised)
    }

    /// The exporter could not write the file: "The file could not be saved. Nothing was kept"; the bytes are dropped.
    public func saveFailed() {
        guard case .save = step else { return }
        pending = nil
        step = .failed(nil, saveFailed: true)
    }

    /// Cancel, Back or Close at any step: the entries read so far and the file's bytes are dropped.
    public func close() {
        drop()
        step = .closed
    }

    private func drop() {
        generation += 1
        job?.cancel()
        job = nil
        pending = nil
    }

    private func row(_ r: AuditRecord, _ c: ExportContext, _ devices: HistoryDevices?) -> ExportRow {
        // As vettid-android writes it: the connection's name as held ("" before it arrived), "Removed connection" once gone.
        // Names go into the file cleaned of every control and format character, never isolated (VAULT-MESSAGING §10.8;
        // mirrors vettid-android #220).
        let connection = r.entry.connectionID.map { id in
            c.connectionNames[id].map { AccountNames.cleaned($0) ?? "" } ?? HistoryStrings.connectionRemoved
        }
        let itemID = AuditKinds.itemOf(r.kind, r.entry.ref)
        let item = itemID.flatMap { id in c.itemNames.map { AccountNames.cleaned($0[id]) ?? HistoryStrings.itemDeleted } }
        let names = EntryNames(
            connection: r.entry.connectionID.flatMap { AccountNames.cleaned(c.connectionNames[$0]) },
            device: devices?.device(r.entry.deviceID)?.rowName,
            item: itemID.flatMap { c.itemNames?[$0] }
        )
        return ExportRow(
            record: r, label: HistoryText.title(r.kind, r.entry.ref, names: names, isolate: false), connectionName: connection,
            deviceName: HistoryText.deviceName(r.entry.deviceID, devices), itemName: item
        )
    }

    private func exportFilters(_ c: ExportContext) -> ExportFilters {
        ExportFilters(c.filter, connectionName: c.filter.connectionID.map {
            c.connectionNames[$0].map { AccountNames.cleaned($0) ?? "" } ?? HistoryStrings.connectionRemoved
        })
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

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
