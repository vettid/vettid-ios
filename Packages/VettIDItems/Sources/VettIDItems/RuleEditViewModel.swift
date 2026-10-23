import Foundation
import Observation
import VettIDData

/// One share rule for one connection (§10.12; a connection has up to 64, each with its own settings): the one tag it shares
/// (owner decision 2026-10-09: one tag per rule, a tag another rule already shares opens that rule), its mode — "Ask me
/// each time" (the default, owner decision 2026-10-03) or "Share automatically" — fetches of each item, and since 0.23.0 the
/// fetches per hour and per day of all its items together, an end (presets or a date and time picked), and whether items
/// that already carry the tag count. The vault's dry run shows what it would match and what saving does to each item
/// (`outcome`, and the `ask` rule that holds an item, `ask_rule_id`: `ask` wins); the connection's other rules covering the
/// same items are shown before it is saved. Saving is "Save rule" in the top bar; leaving with changes asks first. Mirrors
/// vettid-android `RuleEditViewModel`.
@MainActor
@Observable
public final class RuleEditViewModel {
    public private(set) var state: RuleEditState
    /// The vault was cleared (locked, held or due, or wiped): the draft is gone and the screen closes.
    public private(set) var closed = false

    @ObservationIgnored private let connectionID: String
    @ObservationIgnored private let ruleID: String?
    @ObservationIgnored private let sharing: any SharingRepository
    @ObservationIgnored private let items: any ItemsRepository
    @ObservationIgnored private let follows = TaskBag()
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored let work = Work()
    @ObservationIgnored private let previewWork = Work()

    private static let usesDigits = 5
    private static let perHourDigits = 4
    private static let perDayDigits = 5

    /// [ruleID] nil: a new rule. [debounce]: how long the draft rests before the dry run asks (400 ms).
    public init(
        connectionID: String, ruleID: String? = nil, sharing: any SharingRepository, items: any ItemsRepository,
        connections: any ConnectionsRepository,
        debounce: Duration = .milliseconds(400)
    ) {
        self.connectionID = connectionID
        self.ruleID = ruleID
        self.sharing = sharing
        self.items = items
        self.debounce = debounce
        state = RuleEditState(
            draft: RuleDraft(connectionID: connectionID), connectionName: connectionName(connections, connectionID), loading: true
        )
        start()
        let at = items.cleared
        follows.add(follow(self, read: { $0.items.cleared }, apply: { m, c in if c != at { m.dropDraft() } }))
    }

    deinit {
        work.cancelAll()
        previewWork.cancelAll()
        follows.cancelAll()
    }

    private func dropDraft() {
        work.cancelAll()
        previewWork.cancelAll()
        state = RuleEditState(draft: RuleDraft(connectionID: connectionID), connectionName: state.connectionName)
        closed = true
    }

    private func start() {
        let connectionID = connectionID, ruleID = ruleID
        work.launch { [weak self, sharing] in
            do {
                let known = sharing.tags
                let reg = if let known { known } else { try await sharing.refreshTags() }
                if Task.isCancelled { return }
                self?.state.tags = reg.tags.filter { !$0.reserved }.map(\.tag).sorted()
                let rules = try await sharing.rules(connectionID: connectionID).filter { $0.connectionID == connectionID }
                if Task.isCancelled { return }
                self?.state.rules = rules
                self?.state.loading = ruleID != nil
                if let ruleID {
                    guard let r = rules.first(where: { $0.ruleID == ruleID }) else { throw VaultFailure(.notFound) }
                    self?.opened(r)
                    self?.schedulePreview()
                } else {
                    self?.state.loading = false
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                state.loading = false
                state.fail(error)
            }
        }
    }

    /// The edited rule as it is stored.
    private func opened(_ r: ShareRule) {
        var d = RuleDraft.of(r)
        d.connectionID = connectionID
        state.draft = d
        state.expiry = r.expiresAt == nil ? .never : .keep
        state.usesText = r.uses.map(String.init) ?? ""
        state.perHourText = r.perHour.map(String.init) ?? ""
        state.perDayText = r.perDay.map(String.init) ?? ""
        state.loading = false
        state.tags = Array(Set(state.tags + r.tags)).sorted()
        state.readOnly = r.multiTag
    }

    private func change(_ f: (inout RuleDraft) -> Void) {
        if state.readOnly { return }
        f(&state.draft)
        state.error = nil
        state.dirty = true
        schedulePreview()
    }

    /// Chooses the one tag the rule shares (owner decision 2026-10-09). A tag another rule of this connection already shares
    /// is not taken here: the screen opens that rule instead.
    public func selectTag(_ t: String) {
        if state.taken[t] != nil || t == state.tag { return }
        change { $0.tags = [t]; $0.match = .any }
    }

    public func setMode(_ m: ShareMode) { change { $0.mode = m } }

    public func setIncludeExisting(_ on: Bool) { change { $0.includeExisting = on } }

    /// Fetches of each item (§10.12 `uses`, 1–10,000; empty for none): digits only.
    public func setUses(_ v: String) {
        guard !state.readOnly else { return }
        let digits = Self.digits(v, Self.usesDigits)
        state.usesText = digits
        change { $0.uses = Int(digits) }
    }

    /// Fetches per hour of all the rule's items (0.23.0 §10.12 `per_hour`, 1–3,600; empty: no limit).
    public func setPerHour(_ v: String) {
        guard !state.readOnly else { return }
        let digits = Self.digits(v, Self.perHourDigits)
        state.perHourText = digits
        change { $0.perHour = Int(digits) }
    }

    /// Fetches per day of all the rule's items (0.23.0 §10.12 `per_day`, 1–86,400; empty: no limit).
    public func setPerDay(_ v: String) {
        guard !state.readOnly else { return }
        let digits = Self.digits(v, Self.perDayDigits)
        state.perDayText = digits
        change { $0.perDay = Int(digits) }
    }

    private static func digits(_ v: String, _ max: Int) -> String {
        // Decimal digits of any script (Arabic-Indic, …) read as their ASCII digit, as Android's `isDigit` and `toIntOrNull` do.
        let ascii = v.compactMap { c -> Character? in
            let decimal = c.unicodeScalars.allSatisfy { $0.properties.numericType == .decimal }
            guard decimal, let d = c.wholeNumberValue, (0...9).contains(d) else { return nil }
            return Character(String(d))
        }
        return String(ascii.prefix(max))
    }

    /// A preset end from [now] in [zone]; ``RuleExpiry/custom`` opens the date picker (the end changes once a time is picked).
    public func setExpiry(_ e: RuleExpiry, now: Date = Date(), zone: TimeZone = .current) {
        if state.readOnly { return }
        switch e {
        case .keep:
            state.expiry = e
            state.endInvalid = false
        case .custom:
            state.endPicker = .date
            state.endInvalid = false
        default:
            state.expiry = e
            state.endInvalid = false
            change { $0.expiresAt = e.end(from: now, zone: zone) }
        }
    }

    /// The custom end's day was picked: now the time.
    public func pickEndDate(_ day: RuleEnds.Day) { state.endPicker = .time(day) }

    /// The custom end's time was picked: the day at [hour]:[minute] in [zone] becomes the end, sent as UTC (§10.12). An end not
    /// in the future, or more than 3,650 days ahead, is refused (``RuleEditState/endInvalid``) and the end stays.
    public func pickEndTime(hour: Int, minute: Int, zone: TimeZone = .current, now: Date = Date()) {
        guard case .time(let day)? = state.endPicker else { return }
        let at = RuleEnds.of(day, hour: hour, minute: minute, zone: zone)
        guard RuleEnds.allowed(at, now: now) else {
            state.endPicker = nil
            state.endInvalid = true
            return
        }
        state.endPicker = nil
        state.endInvalid = false
        state.expiry = .custom
        change { $0.expiresAt = at }
    }

    public func cancelEndPicker() { state.endPicker = nil }

    private func schedulePreview() {
        previewWork.cancelAll()
        let draft = state.draft
        if draft.tags.isEmpty {
            state.preview = nil
            state.previewing = false
            return
        }
        state.previewing = true
        let wait = debounce
        previewWork.launch { [weak self, sharing] in
            do { try await Task.sleep(for: wait) } catch { return }
            guard let current = self?.state.draft else { return }
            do {
                let p = try await sharing.preview(current)
                // A newer draft cancelled this one: its answer is not shown.
                if Task.isCancelled { return }
                self?.state.preview = p
                self?.state.previewing = false
            } catch {
                if Task.isCancelled { return }
                self?.state.previewing = false
                self?.state.fail(error)
            }
        }
    }

    public func save() {
        guard state.canSave else { return }
        let draft = state.draft
        state.busy = true
        state.error = nil
        work.launch { [weak self, sharing] in
            do {
                try await sharing.saveRule(draft)
                if Task.isCancelled { return }
                self?.state.busy = false
                self?.state.done = true
                self?.state.dirty = false
            } catch {
                guard let self else { return }
                state.busy = false
                state.fail(error)
            }
        }
    }

    /// Back or up with changes: "Discard changes to this rule?" (shown), or not.
    public func askDiscard(_ show: Bool) { state.confirmDiscard = show }

    public func askDelete(_ show: Bool) { state.confirmDelete = show }

    public func delete() {
        guard let id = state.draft.ruleID else { return }
        state.busy = true
        state.confirmDelete = false
        work.launch { [weak self, sharing] in
            do {
                try await sharing.deleteRule(id)
                if Task.isCancelled { return }
                self?.state.busy = false
                self?.state.done = true
                self?.state.dirty = false
            } catch {
                guard let self else { return }
                state.busy = false
                state.fail(error)
            }
        }
    }

    public func dismissError() { state.error = nil }

    /// TEST ONLY: waits until the screen's work is done.
    func settle() async {
        await work.settle()
        await previewWork.settle()
        await work.settle()
    }
}
