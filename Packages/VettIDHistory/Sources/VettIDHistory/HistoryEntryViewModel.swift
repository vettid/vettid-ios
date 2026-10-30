import Foundation
import Observation
import VettIDData

/// The state of an entry's detail. Mirrors vettid-android `HistoryEntryUiState`.
public struct HistoryEntryState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var entry: AuditRecord?
    /// The connection's "First Last"; nil before the names arrived or once the connection is gone.
    public var connectionName: String?
    /// The entry's connection is still in the vault's list (the detail opens it).
    public var connectionExists = false
    /// The entry's connection is a service (VAULT-MESSAGING 0.69.0 §6.4): muting its asks is confirmed first.
    public var connectionIsService = false
    /// The entry's connection's asks are muted (§10.4.1).
    public var asksMuted = false
    /// The mute's confirmation is showing (a service connection's).
    public var confirmMute = false
    public var muting = false
    /// Why the mute failed, nil otherwise.
    public var muteError: FailureKind?
    /// The item the entry refers to (§10.9 item kinds): its current name, and whether it is still in the vault.
    public var itemName: String?
    public var itemExists = false
    /// The item list is held (IOS-PLAN §8 I3.1): an item it does not hold was deleted.
    public var itemsKnown = false
    /// The entry's device (ANDROID-PLAN §4 History): its name while listed by `device.list`, nil otherwise.
    public var deviceName: String?
    /// The device list was read, so a device it does not hold was removed.
    public var devicesKnown = false
    /// The entry's device is listed without a name: known, not removed.
    public var deviceUnnamed = false
    /// The entry's device is this phone.
    public var thisDevice = false
    /// A `not_success` recovery attempt's outcome, from the matching `recovery.open` (IOS-PLAN §4.1).
    public var outcome = AuditKinds.Outcome.unknown
    public var loading = true
    public var missing = false
    public var error: FailureKind?

    public init() {}

    /// A withdrawn request's entry offers "Mute requests from …" while its connection is there and not muted
    /// (VAULT-MESSAGING 0.80.0 §10.4; ANDROID-PLAN 0.1.101).
    public var offersMute: Bool {
        entry?.kind == "connection.authenticate.withdrawn" && connectionExists && connectionName != nil && !asksMuted
    }

    public var description: String {
        "HistoryEntryState(entry: \(entry != nil), loading: \(loading), missing: \(missing), error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// One audit entry (read-only): from the entries History read, else `audit.list{before_seq: seq + 1, limit: 1}`; for a
/// `not_success` recovery attempt, its outcome from the `recovery.open` entries around it. Mirrors vettid-android
/// `HistoryEntryViewModel`.
@MainActor
@Observable
public final class HistoryEntryViewModel {
    /// IOS-PLAN §4.1: the hour on each side of the attempt.
    static let outcomeSpan: TimeInterval = 3_600
    static let outcomeLimit = 100

    @ObservationIgnored private let seq: Int64
    @ObservationIgnored private let history: any HistoryRepository
    @ObservationIgnored private let connections: (any ConnectionsRepository)?
    @ObservationIgnored private let itemNames: (@MainActor () -> [String: String]?)?
    @ObservationIgnored private let work = Work()
    private var local = HistoryEntryState()

    /// [items]: the Vault list, read quietly when it has not been read and followed for the item's name ([itemNames] in
    /// its place: the names by item id, nil before the list is read).
    public init(
        seq: Int64, history: any HistoryRepository, connections: (any ConnectionsRepository)? = nil,
        items: (any ItemsRepository)? = nil, itemNames: (@MainActor () -> [String: String]?)? = nil
    ) {
        self.seq = seq
        self.history = history
        self.connections = connections
        self.itemNames = itemNames ?? AuditKinds.itemNames(items)
        load()
        items?.readIfNotLoaded()
    }

    deinit { work.cancelAll() }

    /// The state now; the item's name as the Vault list has it now (observed through it).
    public var state: HistoryEntryState {
        var s = local
        if itemNames != nil, s.entry != nil { Self.named(&s, itemNames?()) }
        return s
    }

    /// The entry's item by [names] (nil: the list is not read yet).
    static func named(_ s: inout HistoryEntryState, _ names: [String: String]?) {
        let item = s.entry.flatMap { AuditKinds.itemOf($0.kind, $0.entry.ref) }
        s.itemsKnown = names != nil
        s.itemName = item.flatMap { names?[$0] }
        s.itemExists = s.itemName != nil
    }

    public func load() {
        local.loading = true
        local.error = nil
        let seq = seq
        let history = history
        work.launch { [weak self] in
            do {
                let e: AuditRecord?
                if let c = history.cached(seq) {
                    e = c
                } else {
                    e = try await history.auditPage(AuditRequest(beforeSeq: seq + 1, limit: 1)).entries.first { $0.seq == seq }
                }
                let devices = e?.entry.deviceID != nil ? await history.devices(refresh: false) : nil
                self?.show(e, devices: devices)
                if let e { await self?.loadOutcome(e) }
            } catch {
                guard !(error is CancellationError) else { return }
                self?.local.loading = false
                self?.local.error = failureKind(error)
            }
        }
    }

    private func show(_ e: AuditRecord?, devices: HistoryDevices?) {
        var s = local
        s.entry = e
        s.loading = false
        s.missing = e == nil
        let c = e?.entry.connectionID.flatMap { id in connections?.connections.first { $0.id == id } }
        s.connectionName = AccountNames.cleaned(c?.displayName)
        s.connectionExists = c != nil
        s.connectionIsService = c?.isService ?? false
        s.asksMuted = s.asksMuted || c?.asks?.muted == true
        Self.named(&s, itemNames?())
        let id = e?.entry.deviceID
        let listed = id.flatMap { devices?.names[$0] }
        s.devicesKnown = devices != nil
        s.deviceName = listed.flatMap { $0.isEmpty ? nil : $0 }
        s.deviceUnnamed = listed?.isEmpty == true
        s.thisDevice = id != nil && id == devices?.selfID
        local = s
    }

    /// A `not_success` attempt's outcome (IOS-PLAN §4.1): the `recovery.open` and `recovery.attempt` entries of the hour
    /// on each side, matched by time (``RecoveryRefs/matches(_:)``). A failed read leaves the outcome unknown (no line),
    /// never "Details not available".
    private func loadOutcome(_ e: AuditRecord) async {
        guard let at = e.at, e.kind == RecoveryRefs.kindAttempt, RecoveryRefs.attempt(e.entry.ref)?.success == false else { return }
        let since = at.addingTimeInterval(-Self.outcomeSpan)
        let until = at.addingTimeInterval(Self.outcomeSpan)
        let kinds = [RecoveryRefs.kindOpen, RecoveryRefs.kindAttempt]
        let request = AuditRequest(filter: AuditFilter(since: since, until: until), limit: Self.outcomeLimit, kinds: kinds)
        guard let read = try? await history.auditPage(request).entries else { return }
        // A vault that ignored the range or the kinds: kept to what was asked.
        let near = read.filter { r in kinds.contains(r.kind) && r.at.map { $0 >= since && $0 < until } == true }
        let entries = near.contains { $0.seq == e.seq } ? near : near + [e]
        if RecoveryRefs.laterSuccessful(e, in: entries) {
            local.outcome = .laterSuccessful
        } else if let m = RecoveryRefs.matches(entries)[e.seq] {
            local.outcome = .matched(m.outcome, phoneName: m.phoneName)
        } else {
            local.outcome = AuditKinds.Outcome.none
        }
    }

    /// "Mute requests from …" on a withdrawn request's entry: a service connection's is confirmed first, a person's is
    /// muted at once (ANDROID-PLAN 0.1.101).
    public func askMute(_ show: Bool) {
        guard show else { return local.confirmMute = false }
        if local.connectionIsService { local.confirmMute = true } else { mute() }
    }

    /// Mutes the entry's connection's asks (`connection.asks.mute`, §10.4.1), as its detail does.
    public func mute() {
        local.confirmMute = false
        guard let id = local.entry?.entry.connectionID, let connections, !local.muting else { return }
        local.muting = true
        local.muteError = nil
        work.launch { [weak self] in
            do {
                try await connections.setAsksMuted(id, muted: true)
                self?.local.asksMuted = true
            } catch {
                self?.local.muteError = failureKind(error)
            }
            self?.local.muting = false
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
