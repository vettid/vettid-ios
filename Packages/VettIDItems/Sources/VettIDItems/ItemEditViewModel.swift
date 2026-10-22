import Foundation
import Observation
import VettIDData

/// Adding an item from a template or blank, or editing one (§10.7). A `data` item is edited with its values; a `secret` or
/// `critical` one with its stored values kept (VAULT-MESSAGING 0.21.0 §10.7 Kept values): each shows as kept, never
/// revealed, and only what the member types is sent. A critical item is saved with the credential password (one
/// credential operation, §3.5.3); a secret one with nothing more. The sharing notice is the vault's dry run.
///
/// What the member typed is in memory only; when the vault's items are cleared (a lock, the hold, a wipe) the draft and a
/// typed password are dropped and the screen closes (``closed``; chosen; not in the spec, IOS-PLAN §4.7's rule for the
/// drafts of a vault that is no longer open). Mirrors vettid-android `ItemEditViewModel`.
@MainActor
@Observable
public final class ItemEditViewModel {
    public internal(set) var state: ItemEditState
    /// The vault's items were cleared while the screen was open: everything typed is gone, and the screen leaves.
    public internal(set) var closed = false

    @ObservationIgnored let items: any ItemsRepository
    @ObservationIgnored let sharing: (any SharingRepository)?
    @ObservationIgnored let connections: (any ConnectionsRepository)?
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored let impactDelay: Duration
    @ObservationIgnored let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    /// The share rules, read only for a vault without the dry run (before 0.21.0), or to name an `ask` rule.
    @ObservationIgnored var rules: [ShareRule]?
    @ObservationIgnored var noDryRun = false
    @ObservationIgnored var savedTags: [String] = []
    @ObservationIgnored private var impactKey: ImpactKey?
    @ObservationIgnored private var impactTask: Task<Void, Never>?
    /// Whether the content differs from what is stored (a protection change alone saves no content).
    @ObservationIgnored var contentDirty = false
    /// The member confirmed the warning for leaving `critical` (for this save).
    @ObservationIgnored var leaveConfirmed = false
    /// The draft as the item was loaded (nil for a new item): a field that still equals its stored self is sent exactly as
    /// stored, and only a field the member edited or created gets its canonical form (VAULT-MESSAGING §10.7).
    @ObservationIgnored var original: ItemDraft?
    /// The region of a phone number typed without a `+` (the device's locale region; nil: none).
    @ObservationIgnored let region: String?

    struct ImpactKey: Equatable {
        var tags: [String]
        var sensitivity: Sensitivity
    }

    static let codeBadRequest = "bad_request"

    /// [itemID] an item to edit, else a new one from [template] (nil: blank). [sharing] reads the rules (an older vault)
    /// and learns the tags used; [connections] names the connections of the sharing notice.
    public init(
        itemID: String?, template: String? = nil, items: any ItemsRepository, sharing: (any SharingRepository)? = nil,
        connections: (any ConnectionsRepository)? = nil, now: @escaping @Sendable () -> Date = { Date() },
        impactDelay: Duration = .milliseconds(400), region: String? = PhoneInput.deviceRegion
    ) {
        self.region = region
        self.items = items
        self.sharing = sharing
        self.connections = connections
        self.now = now
        self.impactDelay = impactDelay
        state = ItemEditState(itemID: itemID)
        follows.add(follow(self, read: { ItemCategories.customs($0.items.items.map(\.category)) }, apply: { m, c in
            m.state.customCategories = c
        }))
        if let itemID {
            load(itemID)
        } else {
            let t = template.flatMap(ItemTemplates.template)
            state.nameHint = t?.name
            setDraft(t?.draft() ?? ItemTemplates.blank(), dirty: false)
        }
        let at = items.cleared
        follows.add(follow(self, read: { $0.items.cleared }, apply: { m, c in if c != at { m.dropDrafts() } }))
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
        impactTask?.cancel()
    }

    private func dropDrafts() {
        impactTask?.cancel()
        state = ItemEditState(itemID: state.itemID)
        closed = true
    }

    // MARK: - The sharing notice

    /// What saving would do to sharing (§10.7 Dry run): asked again when the tags (or a new item's sensitivity) change,
    /// after a short pause. An existing item whose tags did not change gains and leaves nothing.
    func impact() {
        let s = state
        guard !s.loading, let tags = ItemChecks.normalizeTags(s.draft.tags) else { return }
        let key = ImpactKey(tags: tags, sensitivity: s.draft.sensitivity)
        guard key != impactKey else { return }
        impactKey = key
        impactTask?.cancel()
        if !s.isNew && tags == savedTags { return state.shareImpact = [] }
        impactTask = Task { [weak self, impactDelay] in
            try? await Task.sleep(for: impactDelay)
            guard !Task.isCancelled, let self else { return }
            let impact = await impactOf(s, tags, key.sensitivity)
            guard !Task.isCancelled else { return }
            state.shareImpact = impact
        }
    }

    private func impactOf(_ s: ItemEditState, _ tags: [String], _ sensitivity: Sensitivity) async -> [ShareImpact] {
        do {
            return noDryRun ? try await localImpact(tags, sensitivity) : try await dryRun(s, tags, sensitivity)
        } catch {
            // A vault before 0.21.0 refuses the dry run (no content: nothing is saved); its rules are read instead.
            let f = error as? VaultFailure
            guard f?.kind == .notSupported || (f?.kind == .other && f?.code == Self.codeBadRequest) else { return [] }
            noDryRun = true
            return (try? await localImpact(tags, sensitivity)) ?? []
        }
    }

    private var names: [String: String] {
        Dictionary((connections?.connections ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
    }

    private func dryRun(_ s: ItemEditState, _ tags: [String], _ sensitivity: Sensitivity) async throws -> [ShareImpact] {
        let e = try await items.shareEffect(s.itemID, version: s.itemID == nil ? nil : s.version, sensitivity: sensitivity, tags: tags)
        let names = names
        // v1 pairs no agents (D3): only connection rules are shown.
        var known: [String: ShareRule] = [:]
        if e.shares.contains(where: { $0.askRuleID != nil }), let all = try await allRules() {
            known = Dictionary(all.map { ($0.ruleID, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let gained = e.shares.compactMap { x in
            x.subject.connectionID.map {
                ShareImpact(connectionName: names[$0] ?? "", mode: x.mode, usableOnly: x.usable, askRule: x.askRuleID.flatMap { known[$0] })
            }
        }
        let left = e.withdrawals.compactMap { x in
            x.subject.connectionID.map { ShareImpact(connectionName: names[$0] ?? "", mode: .ask, withdrawn: true) }
        }
        return gained + left
    }

    private func allRules() async throws -> [ShareRule]? {
        if let rules { return rules }
        guard let sharing else { return nil }
        let r = try await sharing.rules(connectionID: nil)
        rules = r
        return r
    }

    /// Before 0.21.0: the connection rules the item newly matches by its tags (§10.12), as the app reads them.
    private func localImpact(_ tags: [String], _ sensitivity: Sensitivity) async throws -> [ShareImpact] {
        let all = try await allRules() ?? []
        let names = names
        return all.filter { $0.connectionID != nil && $0.matches(tags) && !$0.matches(savedTags) }
            .map { ShareImpact(connectionName: names[$0.connectionID ?? ""] ?? "", mode: $0.mode, usableOnly: sensitivity == .critical) }
    }

    // MARK: - Loading and the draft

    /// The item's metadata (`item.get`): a data item with its values, a secret or critical one with them kept.
    private func load(_ itemID: String) {
        state.loading = true
        state.error = nil
        let items = items
        work.launch { [weak self] in
            do {
                let d = try await items.get(itemID)
                self?.edit(d)
            } catch {
                let f = error as? VaultFailure ?? VaultFailure(.other)
                self?.state.loading = false
                self?.state.error = f.kind
                self?.state.errorCode = f.code
                self?.state.limit = f.limit
            }
        }
    }

    func edit(_ d: ItemDetail) {
        savedTags = d.tags
        contentDirty = false
        state.loading = false
        state.version = d.version
        state.prompt = nil
        let loaded = ItemTemplates.withHints(ItemDraft.of(d))
        original = loaded
        setDraft(loaded, dirty: false)
    }

    func setDraft(_ d: ItemDraft, dirty: Bool = true) {
        if dirty { contentDirty = true }
        state.draft = d
        state.check = checkOf(d, state)
        state.dirty = state.dirty || dirty
        state.error = nil
        state.limit = nil
        state.savedButProtection = false
        impact()
    }

    /// The checks of the draft as it would be saved: under the template's name when the name is left empty, in the canonical
    /// form of every field the member edited (§10.7), and with the size limit of the protection it will have (12 KiB for
    /// critical, §10.7).
    func checkOf(_ d: ItemDraft, _ s: ItemEditState) -> DraftCheck {
        var checked = saved(d, s)
        checked.sensitivity = s.protectionTo ?? d.sensitivity
        return ItemChecks.check(checked)
    }

    /// The draft as `item.put` sends it: ``named(_:_:)``, then the canonical forms of the fields the member edited or
    /// created (``CanonicalForms/draft(_:original:region:)``); the others exactly as stored.
    func saved(_ d: ItemDraft, _ s: ItemEditState) -> ItemDraft {
        CanonicalForms.draft(named(d, s), original: original, region: region)
    }

    /// The draft under the template's name when the member left the name empty.
    func named(_ d: ItemDraft, _ s: ItemEditState) -> ItemDraft {
        guard d.name.trimmingCharacters(in: .whitespaces).isEmpty, let hint = s.nameHint else { return d }
        var n = d
        n.name = hint
        return n
    }

    func change(_ f: (inout ItemDraft) -> Void) {
        var d = state.draft
        f(&d)
        setDraft(d)
    }

    func changeField(_ i: Int, _ f: (inout DraftField) -> Void) {
        change { d in
            guard d.fields.indices.contains(i) else { return }
            f(&d.fields[i])
        }
    }

    /// TEST ONLY: waits until the screen's work is done.
    func settle() async { await work.settle() }
}
