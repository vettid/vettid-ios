import Foundation
import VettIDData

/// Saving: the checks, the warning for leaving `critical`, the credential password, then the content and the protection.
/// Mirrors the save of vettid-android `ItemEditViewModel`.
extension ItemEditViewModel {
    public func save() {
        let s = state
        guard !s.busy, !s.loading else { return }
        let check = checkOf(s.draft, s)
        guard check.ok else {
            state.check = check
            state.showErrors = true
            return
        }
        let to = s.protectionTo
        if to != nil, s.draft.sensitivity == .critical, !leaveConfirmed { return state.confirmLeaveCritical = true }
        // One password entry covers the save and the protection change (two credential operations, §10.7).
        if s.draft.sensitivity == .critical || to == .critical {
            state.prompt = PasswordPrompt(.save)
            state.showErrors = true
        } else {
            send(nil, "")
        }
    }

    /// "Move it" after the warning for leaving `critical`: the save goes on (with the password).
    public func confirmLeaveCritical() {
        leaveConfirmed = true
        state.confirmLeaveCritical = false
        save()
    }

    public func dismissLeaveCritical() { state.confirmLeaveCritical = false }

    public func setPassword(_ v: String) {
        state.prompt?.password = v
        state.prompt?.error = nil
    }

    public func cancelPassword() { state.prompt = nil }

    public func submitPassword() {
        guard var p = state.prompt, p.canSend(now()) else { return }
        let pw = p.password
        p.busy = true
        p.password = ""
        p.error = nil
        state.prompt = p
        send(p, pw)
    }

    /// Saves: the content first (`item.put` in the item's current sensitivity, skipped when only the protection changed),
    /// then the protection (`item.sensitivity`), as two operations: `item.put` keeps an item's sensitivity (§10.7). In this
    /// order a refused protection change never loses what the member typed: the content is stored, the editor reloads it
    /// and says the protection did not change, and saving again retries only that.
    private func send(_ p: PasswordPrompt?, _ pw: String) {
        let s = state
        let draft = phonesStored(named(s.draft, s))
        let to = s.protectionTo
        let onlyProtection = !contentDirty && to != nil
        state.busy = true
        state.error = nil
        state.limit = nil
        let items = items, sharing = sharing
        work.launch { [weak self] in
            var stored = false
            do {
                let critical = draft.sensitivity == .critical
                var version = s.version
                let id: String
                if let itemID = s.itemID {
                    id = itemID
                    if !onlyProtection {
                        version = critical
                            ? try await items.updateCritical(itemID, version: s.version, draft: draft, password: pw)
                            : try await items.update(itemID, version: s.version, draft: draft)
                    }
                } else {
                    id = critical ? try await items.createCritical(draft, password: pw) : try await items.create(draft)
                }
                if s.itemID != nil, version != s.version {
                    stored = true
                    self?.contentDirty = false
                    self?.state.version = version
                }
                if let to {
                    let password = critical || to == .critical ? pw : nil
                    _ = try await items.setSensitivity(id, version: version, from: draft.sensitivity, to: to, password: password)
                }
                guard let self else { return }
                state.busy = false
                state.prompt = nil
                state.savedID = id
                state.dirty = false
                // A tag first used here gets its colour stored (owner decision 2026-10-09).
                sharing?.onTagsUsed(draft.tags)
            } catch {
                guard let self else { return }
                let f = error as? VaultFailure ?? VaultFailure(.other)
                state.busy = false
                if stored, let itemID = s.itemID { await reloadAfter(itemID, to) }
                if let p { refused(p, f) } else { failed(f) }
                if stored { state.savedButProtection = true }
            }
        }
    }

    /// After the content was saved and the protection change refused: the item as stored, the new protection still picked.
    private func reloadAfter(_ itemID: String, _ to: Sensitivity?) async {
        guard let d = try? await items.get(itemID) else { return }
        edit(d)
        state.protectionTo = to
        state.dirty = to != nil
        state.check = checkOf(state.draft, state)
    }

    private func refused(_ p: PasswordPrompt, _ f: VaultFailure) {
        state.busy = false
        if f.kind == .badPassword || f.kind == .backoff {
            state.prompt = p.refused(f, now: now())
        } else {
            state.prompt = nil
            failed(f)
        }
    }

    private func failed(_ f: VaultFailure) {
        state.error = f.kind
        state.errorCode = f.code
        state.limit = f.limit
    }
}
