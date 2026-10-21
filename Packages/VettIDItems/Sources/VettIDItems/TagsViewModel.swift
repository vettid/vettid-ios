import Foundation
import Observation
import VettIDData

/// What the tags screen is asking. Mirrors vettid-android `TagDialog`.
public enum TagDialog: Equatable, Sendable {
    case create(name: String = "", description: String = "")
    case edit(tag: TagView, name: String, description: String)
    /// The rename's dry run, to confirm: what it changes and shares.
    case confirmRename(tag: String, into: String, change: TagChange)
    case confirmDelete(tag: String, change: TagChange)
    /// The tag's colour, one of the palette's ten (owner decision 2026-10-09).
    case colour(TagView)
    /// Why `@profile` has no colour to pick: it always uses the member's own.
    case profileColour
}

/// The tags screen's state. Mirrors vettid-android `TagsUiState`.
public struct TagsState: Equatable, Sendable {
    public var registry: TagRegistry?
    public var loading = true
    public var busy = false
    public var dialog: TagDialog?
    public var error: FailureKind?
    /// The code an unmapped refusal names (shown with ``error``), or nil.
    public var errorCode: String?
    /// The limit a `limit` error named (VAULT-MESSAGING 0.21.0 §10.1).
    public var limit: VaultLimit?

    public init(registry: TagRegistry? = nil) { self.registry = registry }

    /// `@profile` first, then the member's tags by name.
    public var tags: [TagView] {
        (registry?.tags ?? []).sorted { a, b in a.reserved != b.reserved ? a.reserved : a.tag < b.tag }
    }
}

/// The tags (VAULT-MESSAGING §10.8): every tag with its items and the share rules that name it (the apps show both on every
/// tag, VAULT-ITEMS §5); create, rename (a merge of one), describe, colour, delete. A rename or delete is previewed with the
/// vault's dry run first; a tag a rule names cannot be deleted (`in_use`); `@profile` is reserved. Mirrors vettid-android
/// `TagsViewModel`.
@MainActor
@Observable
public final class TagsViewModel {
    public private(set) var state: TagsState

    @ObservationIgnored private let sharing: any SharingRepository
    @ObservationIgnored let work = Work()

    /// A tag's description is at most 256 bytes (§10.8); the field stops at 256 characters and the vault checks bytes.
    public static let maxDescription = 256

    public init(sharing: any SharingRepository) {
        self.sharing = sharing
        state = TagsState(registry: sharing.tags)
        refresh()
    }

    deinit { work.cancelAll() }

    public func refresh() {
        run { [sharing] in
            let r = try await sharing.refreshTags()
            return { $0.registry = r }
        }
    }

    public func askCreate() {
        state.dialog = .create()
        state.error = nil
    }

    public func edit(_ t: TagView) {
        guard !t.reserved else { return }
        state.dialog = .edit(tag: t, name: t.tag, description: t.description ?? "")
        state.error = nil
    }

    /// The colour picker of [t]; for `@profile`, why it has none.
    public func askColour(_ t: TagView) {
        state.dialog = t.reserved ? .profileColour : .colour(t)
        state.error = nil
    }

    /// Stores the palette colour [color] (its stored `#rrggbb`) for the picker's tag (`tag.set`, its description and icon
    /// kept); [shown]: it is the one the tag shows already, which only closes the picker.
    public func pickColour(_ color: String, shown: Bool) {
        guard case .colour(let t) = state.dialog else { return }
        if shown { return dismiss() }
        run { [sharing] in
            try await sharing.setTagColor(t.tag, color: color)
            return Self.done(sharing)
        }
    }

    public func setName(_ v: String) {
        switch state.dialog {
        case .create(_, let d): state.dialog = .create(name: v, description: d)
        case .edit(let t, _, let d): state.dialog = .edit(tag: t, name: v, description: d)
        default: break
        }
    }

    public func setDescription(_ v: String) {
        let t = String(v.prefix(Self.maxDescription))
        switch state.dialog {
        case .create(let n, _): state.dialog = .create(name: n, description: t)
        case .edit(let tag, let n, _): state.dialog = .edit(tag: tag, name: n, description: t)
        default: break
        }
    }

    public func dismiss() { state.dialog = nil }

    public func dismissError() { state.error = nil }

    /// Create, or for an edit: a new name goes through the dry run first; a new description is set at once.
    public func save() {
        switch state.dialog {
        case .create(let name, let description):
            guard let n = ItemChecks.normalizeTag(name, reserved: false) else { return }
            run { [sharing] in
                try await sharing.setTag(n, description: description, color: nil)
                return Self.done(sharing)
            }
        case .edit(let t, let name, let description):
            guard let n = ItemChecks.normalizeTag(name, reserved: false) else { return }
            if n != t.tag {
                let from = state.dialog
                run { [sharing] in
                    let change = try await sharing.renameTag(t.tag, into: n, dryRun: true)
                    // Applied only over the form it came from (a late answer opens nothing the member closed).
                    return { s in if s.dialog == from { s.dialog = .confirmRename(tag: t.tag, into: n, change: change) } }
                }
            } else if description != (t.description ?? "") {
                // The colour as the registry has it now (the keeper may have stored one since the form opened); Android
                // sends the form's.
                let color = sharing.tags?.tags.first { $0.tag == t.tag }?.color ?? t.color
                run { [sharing] in
                    try await sharing.setTag(n, description: description, color: color)
                    return Self.done(sharing)
                }
            } else {
                dismiss()
            }
        default: break
        }
    }

    public func confirmRename() {
        guard case .confirmRename(let tag, let into, _) = state.dialog else { return }
        run { [sharing] in
            _ = try await sharing.renameTag(tag, into: into, dryRun: false)
            return Self.done(sharing)
        }
    }

    public func askDelete() {
        guard case .edit(let t, _, _) = state.dialog else { return }
        let from = state.dialog
        run { [sharing] in
            let change = try await sharing.deleteTag(t.tag, dryRun: true)
            return { s in if s.dialog == from { s.dialog = .confirmDelete(tag: t.tag, change: change) } }
        }
    }

    public func confirmDelete() {
        guard case .confirmDelete(let tag, _) = state.dialog else { return }
        run { [sharing] in
            _ = try await sharing.deleteTag(tag, dryRun: false)
            return Self.done(sharing)
        }
    }

    /// The dialog closed and the registry as the repository now has it.
    private static func done(_ sharing: any SharingRepository) -> (inout TagsState) -> Void {
        let r = sharing.tags
        return { s in
            s.dialog = nil
            if let r { s.registry = r }
        }
    }

    /// Runs [block] as one step of the screen: busy meanwhile, then its change of the state, or its failure shown (an
    /// `in_use` closes the dialog it came from).
    private func run(_ block: @escaping @MainActor () async throws -> (inout TagsState) -> Void) {
        state.busy = true
        state.error = nil
        work.launch { [weak self] in
            do {
                let apply = try await block()
                guard let self else { return }
                apply(&state)
                state.busy = false
                state.loading = false
            } catch {
                guard let self else { return }
                let f = error as? VaultFailure ?? VaultFailure(.other)
                state.busy = false
                state.loading = false
                state.error = f.kind
                state.errorCode = f.code
                state.limit = f.limit
                if f.kind == .inUse { state.dialog = nil }
            }
        }
    }

    /// TEST ONLY: waits until the screen's work is done.
    func settle() async { await work.settle() }
}
