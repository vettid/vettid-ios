import Foundation
import VettIDData

/// The member's edits of the draft and its dialogs. Mirrors the setters of vettid-android `ItemEditViewModel`.
extension ItemEditViewModel {
    public func setName(_ v: String) { change { $0.name = v } }

    public func setCategory(_ v: String) { change { $0.category = v } }

    /// A new item's sensitivity; for an existing one the protection it moves to when saved (`item.sensitivity`, §10.7,
    /// after the content): `data` ↔ `secret` needs nothing more, `critical` either way the credential password, and
    /// leaving `critical` the warning first. `@profile` items stay `data` (§10.8): the choice is off while it is on.
    public func setSensitivity(_ to: Sensitivity) {
        if state.isNew { return change { $0.sensitivity = to } }
        if state.inProfile && to != .data { return }
        leaveConfirmed = false
        let target = to == state.draft.sensitivity ? nil : to
        state.protectionTo = target
        state.dirty = state.dirty || target != nil
        state.error = nil
        state.limit = nil
        state.check = checkOf(state.draft, state)
    }

    /// Typing replaces kept notes (§10.7: `notes` instead of `keep_notes`).
    public func setNotes(_ v: String) {
        change {
            $0.notes = v
            $0.keepNotes = false
        }
    }

    /// Removes kept notes: neither `notes` nor `keep_notes` is sent (§10.7).
    public func removeNotes() { setNotes("") }

    public func setTagInput(_ v: String) { state.tagInput = v }

    /// Adds the typed tag (normalised as the vault does, §10.8); an invalid one stays in the field.
    public func addTag() {
        guard let n = ItemChecks.normalizeTag(state.tagInput) else { return }
        change { d in if !d.tags.contains(n) { d.tags.append(n) } }
        state.tagInput = ""
    }

    public func removeTag(_ tag: String) { change { $0.tags.removeAll { $0 == tag } } }

    /// The built-in "Shared profile" choice (`@profile`, §10.8): only a standard (`data`) item can carry it; it can always
    /// be taken off. No template adds it (VAULT-ITEMS 0.1.1).
    public func setInProfile(_ on: Bool) {
        change { d in
            if !on {
                d.tags.removeAll { $0 == ItemChecks.profileTag }
            } else if d.sensitivity == .data, !d.tags.contains(ItemChecks.profileTag) {
                d.tags.append(ItemChecks.profileTag)
            }
        }
    }

    public func setFieldLabel(_ i: Int, _ v: String) { changeField(i) { $0.label = v } }

    /// Typing into a kept field replaces its stored value (it is sent with `value` from now on).
    public func setFieldText(_ i: Int, _ v: String) {
        changeField(i) {
            $0.text = v
            $0.kept = false
        }
    }

    public func setFieldAddress(_ i: Int, _ v: AddressValue) {
        changeField(i) {
            $0.address = v
            $0.kept = false
        }
    }

    /// The kind of a field not yet saved (a saved field keeps its kind: a kept value must keep it, §10.7).
    public func setFieldKind(_ i: Int, _ kind: String) {
        changeField(i) { f in
            guard f.fieldID == nil else { return }
            f.kind = kind
            f.monthYear = false
        }
    }

    public func addField(_ label: String, kind: String) {
        guard FieldKinds.choosable.contains(kind) else { return }
        change { $0.fields.append(DraftField(label: label, kind: kind)) }
    }

    public func askAddField() {
        if state.draft.fields.count < ItemChecks.maxFields { state.dialog = .addField() }
    }

    public func askRenameField(_ i: Int) {
        guard state.draft.fields.indices.contains(i) else { return }
        state.dialog = .renameField(index: i, label: state.draft.fields[i].label)
    }

    /// A saved field keeps its kind (§10.7): nothing to ask.
    public func askFieldKind(_ i: Int) {
        guard state.draft.fields.indices.contains(i), state.draft.fields[i].fieldID == nil else { return }
        state.dialog = .fieldKind(index: i, kind: state.draft.fields[i].kind)
    }

    public func askNewCategory() { state.dialog = .newCategory() }

    /// The label typed in the add or rename dialog, or the name in the new-category one.
    public func setDialogText(_ v: String) {
        switch state.dialog {
        case .addField(_, let kind): state.dialog = .addField(label: v, kind: kind)
        case .renameField(let i, _): state.dialog = .renameField(index: i, label: v)
        case .newCategory: state.dialog = .newCategory(name: v)
        default: break
        }
    }

    public func setDialogKind(_ kind: String) {
        guard FieldKinds.choosable.contains(kind) else { return }
        switch state.dialog {
        case .addField(let label, _): state.dialog = .addField(label: label, kind: kind)
        case .fieldKind(let i, _): state.dialog = .fieldKind(index: i, kind: kind)
        default: break
        }
    }

    public func dismissDialog() { state.dialog = nil }

    /// Applies the open dialog when what it holds is valid (the label checks of §10.7; a category name that gives an
    /// identifier); otherwise it stays open. A new field is appended, ready for its value.
    public func confirmDialog() {
        var applied = false
        switch state.dialog {
        case .addField(let label, let kind):
            if let l = validLabel(label) {
                let at = state.draft.fields.count
                addField(l, kind: kind)
                if state.draft.fields.count > at { state.focusField = at }
                applied = true
            }
        case .renameField(let i, let label):
            if let l = validLabel(label) {
                setFieldLabel(i, l)
                applied = true
            }
        case .fieldKind(let i, let kind):
            setFieldKind(i, kind)
            applied = true
        case .newCategory(let name):
            if let id = ItemCategories.derive(name).id {
                setCategory(id)
                applied = true
            }
        case nil:
            break
        }
        if applied { state.dialog = nil }
    }

    /// The trimmed label when it passes §10.7's checks, else nil.
    private func validLabel(_ v: String) -> String? {
        let t = v.trimmingCharacters(in: .whitespaces)
        return ItemChecks.labelProblems(t).isEmpty ? t : nil
    }

    public func fieldFocused() { state.focusField = nil }

    public func removeField(_ i: Int) {
        change { d in if d.fields.indices.contains(i) { d.fields.remove(at: i) } }
    }

    public func moveField(_ i: Int, by delta: Int) {
        change { d in
            let j = i + delta
            guard d.fields.indices.contains(i), d.fields.indices.contains(j) else { return }
            d.fields.insert(d.fields.remove(at: i), at: j)
        }
    }

    public func askDiscard(_ show: Bool) { state.confirmDiscard = show }

    public func dismissError() {
        state.error = nil
        state.limit = nil
    }
}
