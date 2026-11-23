import Foundation
import VettIDData

/// A confirmation on the item's page (AA7): each asks before the change is made in the draft.
public enum WaysConfirm: Equatable, Sendable {
    case runOff, proxyOff, revealOn, eachOff
    case removeLastProgram(Int)
    case forgetPin(Int)
}

/// What the last save or event came to, shown once.
public enum WaysNotice: Equatable, Sendable {
    case saved, lockedAgain, conflict, readOnlyLocked
    case failed(FailureKind)
}

/// The unlock window prompt of a widening save (AA7 "Saving"). [password] lives here only while the prompt is up; nothing prints it.
public struct WaysPrompt: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var password = ""
    public var sending = false
    /// The prompt follows a `credential_locked`: its request is the same request, sent once more.
    public var resend = false
    /// The refusal the prompt shows: a wrong password, a backoff, the alarm, with the vault's code when it has one.
    public var error: FailureKind?

    public init(resend: Bool = false) { self.resend = resend }

    public var alarm: Bool { error == .credentialFrozen || error == .rotationRequired }

    public var description: String { "WaysPrompt" }
    public var debugDescription: String { "WaysPrompt" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A byte-for-byte comparison of two strings (the vault's: never Swift's canonical equivalence).
func sameBytes(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// The item's page (ANDROID-PLAN 0.1.137 AA7). [read] is the vault's `item_ways` as last read, [draft] the member's edits (nil for a
/// read-only page, which offers only to turn a whole way off). Nothing is sent while the member edits. Holds settings, programs,
/// hosts and the vault's own text: nothing but the type is printed. Mirrors vettid-android `ItemWaysUiState` (without AA9's folders).
public struct ItemWaysState: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var agent: DeviceInfo?
    public var itemName: String?
    /// The names of the items are read (``itemName`` nil is then an item the member no longer has).
    public var namesLoaded = false
    public var loadError: FailureKind?
    public var read: ItemWaysRead?
    public var draft: ItemWays?
    public var saving = false
    public var confirm: WaysConfirm?
    public var prompt: WaysPrompt?
    public var notice: WaysNotice?
    /// `not_found`, or the event that says the settings were deleted: the page says so and saves nothing.
    public var notIncluded = false
    /// `not_found` to a save: the page says so, then goes back.
    public var leaving = false
    /// A `leash.item.changed` for this item while the draft holds changes: kept, with **Show the current ones**.
    public var changedElsewhere = false
    /// The program whose page is open (its index in the draft), or nil.
    public var openProgram: Int?
    public var programInput = ""
    public var programProblem: ProgramProblem?
    /// The open program's text as edited (changing it forgets the fingerprint).
    public var editInput = ""
    public var editProblem: ProgramProblem?
    public var variableInput = ""
    public var variableProblem: VariableProblem?
    public var hostInput = ""
    public var hostProblem: HostProblem?
    /// "Add a host" was opened by turning the API switch on (`proxy` needs one host): its field takes focus.
    public var addingHost = false
    /// The fingerprint shown in full (all 64 digits), or nil.
    public var fullPin: String?
    public var windowNotClosed: WindowNotClosed?
    public var ownerCheck = false
    /// The last save was refused with `bad_request` (AA7 "Saving"): the vault's message as shown (``VaultReason``), "" when it is
    /// shown by the fallback text; nil when there is none. Kept on the page until the next save or edit.
    public var refused: String?

    public init() {}

    public var readOnly: Bool { read?.readOnly == true }

    /// The agent's name as a sentence has it (isolated); "Loading…" until the agent is known.
    public var agentName: String { agent.map { DeviceTexts.sentenceName($0) } ?? ItemWaysStrings.waysItemLoading }

    /// The item's name, isolated as an agent's is; "Loading…" until the names are read, "An item you no longer have" after.
    public var shownItemName: String {
        if let itemName { return AccountNames.isolate(itemName) }
        return namesLoaded ? ItemWaysStrings.waysItemGone : ItemWaysStrings.waysItemLoading
    }

    /// The draft or the open program's field holds something not saved.
    public var holdsChanges: Bool { dirty || editPending }

    /// The member holds anything a fresh start of the page would lose: input, an open program, a dialog or a sheet.
    public var busy: Bool { holdsInput || openProgram != nil || confirm != nil || addingHost || fullPin != nil }

    /// A read-only page can send a turn-off: the answer read strictly, and for the agent asked about.
    public var canTurnOff: Bool { read?.strict != nil && read?.foreign == false }

    /// The draft differs from what was read.
    public var dirty: Bool { draft != nil && !ItemWaysRules.identical(draft, read?.ways) }

    /// The open program's text was changed in its field and not applied yet.
    public var editPending: Bool {
        guard let i = openProgram, let p = draft?.run?.programs[safe: i] else { return false }
        return !sameBytes(p.program, editInput)
    }

    /// Whether the draft can be saved: changed, and every field the vault checks reads as it would accept it.
    public var canSave: Bool { (dirty || editPending) && !saving && !notIncluded && draftValid }

    private var draftValid: Bool {
        guard let p = draft?.proxy else { return true }
        return !p.hosts.isEmpty && ItemWaysRules.headerValid(p.header) && ItemWaysRules.prefixValid(p.prefix)
    }

    /// The screen holds input the member would lose by leaving (the shell's `holdsInput`).
    public var holdsInput: Bool {
        dirty || editPending || prompt != nil || !programInput.isEmpty || !variableInput.isEmpty || !hostInput.isEmpty
    }

    /// The open program's recorded pin was taken out in the draft: "Fingerprint forgotten when you save".
    public func pinForgotten(_ p: RunProgram) -> Bool {
        guard p.sha256 == nil else { return false }
        return read?.ways?.run?.programs.contains { sameBytes($0.program, p.program) && $0.sha256 != nil } == true
    }

    /// After a `saved` of [sent]: the draft starts again from [saved], unless the member changed it while the save was out. Then
    /// the change is kept and moved onto the saved version when the vault saved exactly what was sent; otherwise it stays on the
    /// read it was made from, with "Another device changed these settings." (its save meets `conflict`).
    func afterSaved(_ saved: ItemWaysRead, sent: ItemWays?) -> ItemWaysState {
        var base = self
        base.prompt = nil
        base.notice = .saved
        let now = saved.ways
        if sent == nil || draft == nil || ItemWaysRules.identical(draft, sent) {
            base.read = saved
            base.draft = now
            base.changedElsewhere = false
        } else if let now, let sent, var d = draft, ItemWaysRules.sameSettings(withVersion(sent, now.version), now) {
            d.version = now.version
            base.read = saved
            base.draft = d
            base.changedElsewhere = false
        } else {
            base.changedElsewhere = true
        }
        return base
    }

    private func withVersion(_ w: ItemWays, _ v: Int64?) -> ItemWays {
        var w = w
        w.version = v
        return w
    }

    /// After a read [r] that is the latest (see the view model's `load`): [force] starts the page again; otherwise the same version
    /// is taken in quietly when nothing changed or the draft can follow it, a new one (or any change while the member holds
    /// something, or [keep]) is kept with the notice, and else the page starts again from [r].
    func afterRead(_ r: ItemWaysRead, force: Bool, keep: Bool, before: ItemWays?) -> ItemWaysState {
        var s = self
        let clean = ItemWaysRules.identical(draft, read?.ways)
        if !force, let cur = read, r.ways?.version == cur.ways?.version, ItemWaysRules.identical(r.ways, cur.ways) || clean {
            s.read = r
            if clean { s.draft = r.ways }
            s.notIncluded = false
        } else if !force, r.readOnly {
            // The same version, or a new one, that this page cannot edit (a repeated pair, an unknown member): the draft was made
            // from a reading the vault no longer gives, and a save from it would meet no `conflict`. The page takes the reading.
            s.read = r
            s.draft = nil
            s.notIncluded = false
            s.changedElsewhere = false
            s.prompt = nil
            s.openProgram = nil
            s.editInput = ""
            s.addingHost = false
            s.confirm = nil
            s.fullPin = nil
        } else if !force, keep || busy || !ItemWaysRules.identical(draft, before) {
            // Kept, on the read it was made from: its save meets the vault's `conflict`, with no prompt.
            s.notIncluded = false
            s.changedElsewhere = true
        } else {
            s.read = r
            s.draft = r.ways
            s.notIncluded = false
            s.changedElsewhere = false
            s.prompt = nil
            s.openProgram = nil
            s.editInput = ""
            s.addingHost = false
            s.confirm = nil
            s.fullPin = nil
        }
        return s
    }

    public var description: String { "ItemWaysState" }
    public var debugDescription: String { "ItemWaysState" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public extension Array {
    /// The element at [i], or nil when there is none.
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
