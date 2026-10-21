import Foundation
import Observation
import VettIDData

/// What the detail screen is confirming. Mirrors vettid-android `DetailDialog`.
public enum DetailDialog: Sendable {
    case delete, protectionPick, leaveCritical
}

/// An item's detail state; never printed or reflected with its values. Mirrors vettid-android `ItemDetailUiState`.
public struct ItemDetailState: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let itemID: String
    public var item: ItemDetail?
    public var loading = true
    /// The item is gone (`not_found`): deleted here or on another device.
    public var missing = false
    public var error: FailureKind?
    public var errorCode: String?
    public var busy = false
    /// Masked fields (passwords, one-time code seeds) the member chose to see, by field id.
    public var shown: Set<String> = []
    public var prompt: PasswordPrompt?
    public var dialog: DetailDialog?
    /// The sensitivity the member picked, waiting for the password or the warning.
    public var target: Sensitivity?
    public var deleted = false
    /// The limit a `limit` error named (VAULT-MESSAGING 0.21.0 §10.1).
    public var limit: VaultLimit?

    public init(itemID: String, item: ItemDetail? = nil) {
        self.itemID = itemID
        self.item = item
    }

    public var revealed: Bool { item?.revealed == true }

    public var description: String { "ItemDetailState(\(itemID), revealed: \(revealed), busy: \(busy))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// An item (§10.7): `data` values at once; a `secret` item's values after the member confirms with the phone's lock
/// (``reveal()``, audited by the vault, the screen asks first); a `critical` item's after the credential password
/// (``open()``). Values are dropped again when the screen leaves the foreground (``hide()``) and whenever the vault's
/// items are cleared (a lock, the hold, a wipe). Delete and the sensitivity change follow §10.7: a critical item's need the
/// password, and leaving `critical` warns first. Mirrors vettid-android `ItemDetailViewModel`.
@MainActor
@Observable
public final class ItemDetailViewModel {
    public private(set) var state: ItemDetailState

    @ObservationIgnored private let items: any ItemsRepository
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored let work = Work()
    @ObservationIgnored private let follows = TaskBag()

    public init(itemID: String, items: any ItemsRepository, now: @escaping @Sendable () -> Date = { Date() }) {
        self.items = items
        self.now = now
        state = ItemDetailState(itemID: itemID)
        load()
        // Cleared (a lock, the hold, a wipe): nothing revealed is kept, nor a typed password.
        follows.add(follow(self, read: { $0.items.cleared }, apply: { m, _ in m.dropValues() }))
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    private func dropValues() {
        hide()
        state.prompt = nil
    }

    public func load() {
        state.loading = true
        state.error = nil
        let id = state.itemID, items = items
        work.launch { [weak self] in
            do {
                let d = try await items.get(id)
                self?.state.item = d
                self?.state.loading = false
                self?.state.missing = false
            } catch {
                guard let self else { return }
                let f = error as? VaultFailure ?? VaultFailure(.other)
                let gone = f.kind == .notFound
                state.loading = false
                state.missing = gone
                state.error = gone ? nil : f.kind
                state.errorCode = gone ? nil : f.code
            }
        }
    }

    /// A secret item's values (`item.reveal`), after the screen confirmed the holder; a critical one asks the password.
    public func reveal() {
        guard let item = state.item else { return }
        if item.sensitivity == .critical { return open() }
        let id = state.itemID, items = items
        run(nil) { m in
            let d = try await items.reveal(id)
            m.state.item = d
        }
    }

    /// A critical item's values: the credential password first.
    public func open() {
        state.prompt = PasswordPrompt(.open)
        state.error = nil
    }

    /// Drops the values (the screen left the foreground, or the member hid them); a data item keeps its own.
    public func hide() {
        state.item = state.item?.hidden()
        state.shown = []
    }

    public func toggleShown(_ fieldID: String) {
        if state.shown.contains(fieldID) { state.shown.remove(fieldID) } else { state.shown.insert(fieldID) }
    }

    public func setPassword(_ v: String) {
        state.prompt?.password = v
        state.prompt?.error = nil
    }

    public func cancelPassword() {
        state.prompt = nil
        state.target = nil
    }

    public func askDelete() { state.dialog = .delete }

    public func askProtection() { state.dialog = .protectionPick }

    public func dismissDialog() {
        state.dialog = nil
        state.target = nil
    }

    public func dismissError() {
        state.error = nil
        state.limit = nil
    }

    /// Delete confirmed: a critical item asks for the password next.
    public func confirmDelete() {
        guard let item = state.item else { return }
        state.dialog = nil
        if item.sensitivity == .critical { return state.prompt = PasswordPrompt(.delete) }
        let id = state.itemID, items = items
        run(nil, deleting: true) { _ in try await items.delete(id, sensitivity: item.sensitivity, password: nil) }
    }

    /// The member picked [to]: `data` ↔ `secret` at once; into `critical` with the password; out of it after a warning.
    public func pickProtection(_ to: Sensitivity) {
        guard let item = state.item else { return }
        if to == item.sensitivity { return dismissDialog() }
        if item.sensitivity == .critical {
            state.dialog = .leaveCritical
            state.target = to
        } else if to == .critical {
            state.dialog = nil
            state.target = to
            state.prompt = PasswordPrompt(.protection)
        } else {
            state.dialog = nil
            let id = state.itemID, items = items
            run(nil) { m in
                _ = try await items.setSensitivity(id, version: item.version, from: item.sensitivity, to: to, password: nil)
                try await m.reload()
            }
        }
    }

    /// "Move it out of the credential" after the warning: the password next.
    public func confirmLeaveCritical() {
        state.dialog = nil
        state.prompt = PasswordPrompt(.protection)
    }

    public func submitPassword() {
        guard var p = state.prompt, let item = state.item, p.canSend(now()) else { return }
        let pw = p.password
        p.busy = true
        p.password = ""
        p.error = nil
        state.prompt = p
        let id = state.itemID, items = items
        switch p.purpose {
        case .open:
            run(p) { m in
                let d = try await items.revealCritical(id, password: pw)
                m.state.item = d
                m.state.prompt = nil
            }
        case .delete:
            run(p, deleting: true) { _ in try await items.delete(id, sensitivity: item.sensitivity, password: pw) }
        case .protection:
            guard let to = state.target else { return cancelPassword() }
            run(p) { m in
                _ = try await items.setSensitivity(id, version: item.version, from: item.sensitivity, to: to, password: pw)
                m.state.prompt = nil
                m.state.target = nil
                try await m.reload()
            }
        case .save:
            cancelPassword()
        }
    }

    private func reload() async throws {
        state.item = try await items.get(state.itemID)
        state.shown = []
    }

    /// Runs [block]: busy meanwhile; a wrong password or its backoff stays on the password step ([prompt]); any other
    /// failure closes it and shows why.
    private func run(
        _ prompt: PasswordPrompt?, deleting: Bool = false, _ block: @escaping @MainActor (ItemDetailViewModel) async throws -> Void
    ) {
        state.busy = true
        state.error = nil
        let now = now
        work.launch { [weak self] in
            guard let self else { return }
            do {
                try await block(self)
                state.busy = false
                state.prompt = nil
                state.deleted = state.deleted || deleting
            } catch {
                let f = error as? VaultFailure ?? VaultFailure(.other)
                state.busy = false
                if let prompt, f.kind == .badPassword || f.kind == .backoff {
                    state.prompt = prompt.refused(f, now: now())
                } else {
                    state.prompt = nil
                    state.target = nil
                    state.error = f.kind
                    state.errorCode = f.code
                    state.limit = f.limit
                    state.missing = f.kind == .notFound
                }
            }
        }
    }

    /// TEST ONLY: waits until the screen's work is done.
    func settle() async { await work.settle() }
}
