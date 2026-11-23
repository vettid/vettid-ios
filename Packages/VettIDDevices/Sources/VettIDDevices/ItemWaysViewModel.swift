import Foundation
import Observation
import VettIDData

/// The item's page (ANDROID-PLAN 0.1.137 AA7): one `item_ways`, edited in a draft and saved with **Save**. Nothing is sent while the
/// member edits. A widening save asks for the credential password every time (the prompt); a narrowing one does not. The password
/// lives only in the prompt's state, and is handed to the repository once. Work cut off by a lock or the app leaving is silent.
/// Mirrors vettid-android `ItemWaysViewModel` (without AA9's folders).
@MainActor
@Observable
public final class ItemWaysViewModel {
    /// The app's suggestions when the API switch is turned on (not vault defaults; owner-approved, open item 6).
    public static let defaultHeader = "Authorization"
    public static let defaultPrefix = "Bearer "

    @ObservationIgnored private let agentID: String
    @ObservationIgnored private let itemID: String
    @ObservationIgnored private let repo: any ItemWaysRepository
    @ObservationIgnored private let devices: any DevicesRepository
    @ObservationIgnored private let items: any ItemsRepository
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    /// The latest read started: an older one's answer is never applied (it may be of an older version).
    @ObservationIgnored private var loads = 0
    /// The last event this page has taken in (the repository holds the last one, also from before this page opened).
    @ObservationIgnored private var seenEvent: Int?
    /// The repository's count of clears this page has taken in: a lock, the hold or a wipe ends what the page holds.
    @ObservationIgnored private var seenCleared: Int
    private var local = ItemWaysState()

    public init(agentID: String, itemID: String, repo: any ItemWaysRepository, devices: any DevicesRepository, items: any ItemsRepository) {
        self.agentID = agentID
        self.itemID = itemID
        self.repo = repo
        self.devices = devices
        self.items = items
        seenEvent = repo.event?.seq
        seenCleared = repo.cleared
        load(force: true)
        follows.add(follow(self, read: { $0.repo.event }, apply: { $0.onEvent($1) }))
        follows.add(follow(self, read: { $0.repo.cleared }, apply: { $0.onCleared($1) }))
        if items.load != .loaded { items.refreshQuietly() }
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    public var state: ItemWaysState {
        var s = local
        s.agent = devices.devices.first { sameBytes($0.id, agentID) }
        let item = items.items.first { sameBytes($0.itemID, itemID) }
        s.itemName = item?.name
        s.namesLoaded = items.load == .loaded
        s.windowNotClosed = repo.windowNotClosed
        return s
    }

    // MARK: Reading

    /// **Show the current ones**: the vault's settings, the draft started again from them.
    public func load() { load(force: true) }

    /// Try again after a read failed: whatever the member holds is kept (with "changed elsewhere" if the settings did).
    public func retry() {
        if local.busy { load(force: false, keep: true) } else { load(force: true) }
    }

    /// The page is shown (every return to it): read again when the member holds nothing (no change, no typed text, no open
    /// program, dialog or sheet), since this phone's own approval of a run records a pin without a `leash.item.changed` to this
    /// phone (the vault skips the deciding device). Before the first read has answered, nothing.
    public func returned() {
        if local.read != nil && !local.busy && !local.saving { load(force: false) }
    }

    /// Reads the settings. Only the latest read is applied. [force] (opening, Show the current ones, a conflict) starts the page
    /// again from them. Otherwise (an event's or a return's re-read, Try again with something held):
    /// - the same version is taken in quietly (a recorded pin), a clean draft following it, nothing else touched; with a
    ///   changed draft only when nothing else changed (else the next case, so the draft and its read stay together);
    /// - a new version while the member holds anything, or changed the draft while the read was out, or [keep], keeps all of it
    ///   with "Another device changed these settings." (AA7 "While the page is open");
    /// - else the page starts again from the new version.
    private func load(force: Bool, keep: Bool = false) {
        loads += 1
        let n = loads
        let before = local.draft
        local.loadError = nil
        let (repo, agentID, itemID) = (repo, agentID, itemID)
        work.launch { [weak self] in
            do {
                let r = try await repo.read(agentID, itemID)
                guard let self, n == loads else { return }
                if let r {
                    local = local.afterRead(r, force: force, keep: keep, before: before)
                } else {
                    local.notIncluded = true
                    local.prompt = nil
                }
            } catch where isSilent(error) {
                // Cut off by a lock or the app leaving.
            } catch {
                guard let self, n == loads else { return }
                let kind = failureKind(error)
                local.loadError = kind
                local.ownerCheck = kind == .ownerCheckRequired
            }
        }
    }

    /// The vault locked, was held or wiped: nothing read before it is kept, and no prompt, password or answer survives it. The
    /// page is empty (and its work cut off) until it is shown again.
    private func onCleared(_ n: Int) {
        guard n != seenCleared else { return }
        seenCleared = n
        loads += 1
        work.cancelAll()
        local = ItemWaysState()
    }

    private func onEvent(_ e: ItemWaysEvent?) {
        guard let e, e.seq != seenEvent else { return }
        seenEvent = e.seq
        guard case .item(let agent, let item, _, let deleted) = e.kind, sameBytes(agent, agentID), sameBytes(item, itemID) else { return }
        if deleted {
            local.notIncluded = true
            local.prompt = nil
        } else if local.dirty {
            local.changedElsewhere = true
        } else {
            load(force: false)
        }
    }

    private func edit(_ change: (inout ItemWays) -> Void) {
        guard var d = local.draft else { return }
        change(&d)
        local.draft = d
        local.refused = nil
    }

    // MARK: The switches

    public func setRun(_ on: Bool) {
        if on {
            // A vault whose answer carried `run.folders` keeps the list (empty) when Run is turned back on (AA9: only a run
            // binding's first creation learns it from the answer).
            let folders: [RunFolder]? = local.read?.foldersKnown == true ? [] : nil
            edit {
                $0.ways.insert(.run)
                $0.run = RunSettings(folders: folders)
            }
        } else {
            local.confirm = .runOff
        }
    }

    public func setProxy(_ on: Bool) {
        if on {
            edit {
                $0.ways.insert(.proxy)
                $0.proxy = ProxySettings(hosts: [], header: Self.defaultHeader, prefix: Self.defaultPrefix)
            }
            local.addingHost = true
        } else {
            local.confirm = .proxyOff
        }
    }

    public func setReveal(_ on: Bool) {
        if on {
            local.confirm = .revealOn
        } else if local.readOnly {
            turnOff(.reveal)
        } else {
            edit { $0.ways.remove(.reveal) }
        }
    }

    public func setEach(_ on: Bool) {
        if on {
            edit { $0.run?.each = true }
        } else if local.draft?.run?.programs.isEmpty != false {
            // Off only with a program (AA7): the switch is disabled then, and the view model holds to it too.
            return
        } else {
            local.confirm = .eachOff
        }
    }

    public func dismissConfirm() { local.confirm = nil }

    /// The confirmation's affirmative button.
    public func confirm() {
        guard let c = local.confirm else { return }
        local.confirm = nil
        switch c {
        case .runOff:
            if local.readOnly { turnOff(.run) } else { edit { $0.ways.remove(.run); $0.run = nil } }
        case .proxyOff:
            if local.readOnly { turnOff(.proxy) } else { edit { $0.ways.remove(.proxy); $0.proxy = nil } }
        case .revealOn:
            edit { $0.ways.insert(.reveal) }
        case .eachOff:
            edit { $0.run?.each = false }
        case .removeLastProgram(let index):
            removeProgramAt(index)
            local.openProgram = nil
        case .forgetPin(let index):
            editProgram(index) { $0.sha256 = nil; $0.path = nil }
        }
    }

    // MARK: Programs

    public func setProgramInput(_ v: String) {
        local.programInput = v
        local.programProblem = nil
    }

    public func addProgram() {
        guard let programs = local.draft?.run?.programs else { return }
        let p = local.programInput
        if let problem = ItemWaysRules.addProgramProblem(programs, p) {
            local.programProblem = problem
            return
        }
        edit { $0.run?.programs.append(RunProgram(program: p)) }
        local.programInput = ""
        local.programProblem = nil
    }

    public func openProgram(_ index: Int) {
        guard let p = local.draft?.run?.programs[safe: index] else { return }
        local.openProgram = index
        local.editInput = p.program
        local.editProblem = nil
        local.variableInput = ""
        local.variableProblem = nil
    }

    /// Back from the program's page: a changed program text is applied first. When it is refused the page stays with the problem
    /// shown; Back again leaves and drops that text. False when the page stays.
    @discardableResult
    public func closeProgram() -> Bool {
        let refusedBefore = local.editProblem != nil
        if !refusedBefore && !applyEdit() { return false }
        local.openProgram = nil
        local.editInput = ""
        local.editProblem = nil
        local.variableInput = ""
        local.variableProblem = nil
        return true
    }

    public func setEditInput(_ v: String) {
        local.editInput = v
        local.editProblem = nil
    }

    /// Changing the program is removing it and adding another (AA7): checked as an added program against the others, its
    /// fingerprint forgotten, its variables kept. False, with the problem shown, when the new text is refused.
    @discardableResult
    public func applyEdit() -> Bool {
        guard let i = local.openProgram, let programs = local.draft?.run?.programs, let cur = programs[safe: i] else { return true }
        let text = local.editInput
        if sameBytes(text, cur.program) { return true }
        let others = programs.enumerated().filter { $0.offset != i }.map(\.element)
        if let problem = ItemWaysRules.addProgramProblem(others, text) {
            local.editProblem = problem
            return false
        }
        editProgram(i) { $0 = RunProgram(program: text, env: $0.env) }
        return true
    }

    public func removeProgram(_ index: Int) {
        guard let programs = local.draft?.run?.programs else { return }
        if programs.count == 1 {
            // Removing the last program is a widening (the item becomes unbound): it asks first.
            local.confirm = .removeLastProgram(index)
            return
        }
        removeProgramAt(index)
        local.openProgram = nil
    }

    private func removeProgramAt(_ index: Int) {
        edit { w in
            guard var r = w.run, r.programs.indices.contains(index) else { return }
            r.programs.remove(at: index)
            // Emptying the program list turns Ask me before each run back on.
            if r.programs.isEmpty { r.each = true }
            w.run = r
        }
    }

    private func editProgram(_ index: Int, _ change: (inout RunProgram) -> Void) {
        edit { w in
            guard var r = w.run, r.programs.indices.contains(index) else { return }
            change(&r.programs[index])
            w.run = r
        }
    }

    public func forgetPin(_ index: Int) { local.confirm = .forgetPin(index) }

    public func showFullPin(_ sha256: String?) { local.fullPin = sha256 }

    // MARK: Variables

    public func setVariableInput(_ v: String) {
        local.variableInput = v
        local.variableProblem = nil
    }

    public func addVariable() {
        guard let i = local.openProgram, let env = local.draft?.run?.programs[safe: i]?.env else { return }
        let name = local.variableInput
        if let problem = ItemWaysRules.variableProblem(env, name) {
            local.variableProblem = problem
            return
        }
        if !env.contains(where: { sameBytes($0, name) }) { editProgram(i) { $0.env.append(name) } }
        local.variableInput = ""
        local.variableProblem = nil
    }

    public func removeVariable(_ name: String) {
        guard let i = local.openProgram else { return }
        editProgram(i) { p in p.env.removeAll { sameBytes($0, name) } }
    }

    // MARK: The API settings

    public func setHostInput(_ v: String) {
        local.hostInput = v
        local.hostProblem = nil
    }

    public func addHost() {
        guard let p = local.draft?.proxy else { return }
        let host = ItemWaysRules.normalizeHost(local.hostInput)
        if let problem = ItemWaysRules.addHostProblem(p.hosts, host) {
            local.hostProblem = problem
            return
        }
        edit { $0.proxy?.hosts.append(host) }
        local.hostInput = ""
        local.hostProblem = nil
        local.addingHost = false
    }

    /// The last host cannot be removed (turn the switch off instead).
    public func removeHost(_ host: String) {
        guard let p = local.draft?.proxy, p.hosts.count > 1 else { return }
        edit { $0.proxy?.hosts.removeAll { sameBytes($0, host) } }
    }

    public func setHeader(_ v: String) { edit { $0.proxy?.header = v } }

    public func setPrefix(_ v: String) { edit { $0.proxy?.prefix = v } }

    // MARK: Saving

    public func save() {
        guard local.canSave else { return }
        if local.openProgram != nil && !applyEdit() { return }
        send(password: nil, resent: false)
    }

    public func setPassword(_ v: String) {
        guard local.prompt != nil else { return }
        local.prompt?.password = v
        local.prompt?.error = nil
    }

    public func submitPassword() {
        guard let p = local.prompt, !p.password.isEmpty, !p.sending else { return }
        local.prompt?.password = ""
        local.prompt?.sending = true
        send(password: p.password, resent: p.resend)
    }

    public func dismissPrompt() {
        if local.prompt?.sending == true { return }
        local.prompt = nil
    }

    private func send(password: String?, resent: Bool) {
        // An item no longer included saves nothing (AA7), also from a prompt that was open when that was learnt.
        guard let cur = local.read, let next = local.draft, !local.notIncluded else { return }
        local.saving = true
        local.refused = nil
        let repo = repo
        let started = repo.cleared
        work.launch { [weak self] in
            let result: ItemWaysSave?
            do {
                result = try await repo.save(cur, next, password: password, resent: resent)
            } catch where isSilent(error) {
                result = nil
            } catch {
                result = .failed(error as? VaultFailure ?? VaultFailure(.other))
            }
            // The vault answered after a lock, a hold or a wipe (`saved` all the same): the page it was for is gone.
            guard let self, repo.cleared == started else { return }
            local.saving = false
            guard let result else { return }
            // One resend after `credential_locked`, whatever the repository answers (AA7 "Saving").
            if resent, case .credentialLocked = result { onSaved(.lockedAgain, sent: next) } else { onSaved(result, sent: next) }
        }
    }

    private func turnOff(_ way: ItemWay) {
        guard let cur = local.read, !local.notIncluded else { return }
        local.saving = true
        local.refused = nil
        let repo = repo
        let started = repo.cleared
        work.launch { [weak self] in
            let result: ItemWaysSave?
            do {
                result = try await repo.turnOff(cur, way.wire)
            } catch where isSilent(error) {
                result = nil
            } catch {
                result = .failed(error as? VaultFailure ?? VaultFailure(.other))
            }
            guard let self, repo.cleared == started else { return }
            local.saving = false
            if let result { onSaved(result, sent: nil) }
        }
    }

    /// [sent] is the draft the save sent: an edit made while it was out stays in the draft after a `saved`.
    private func onSaved(_ r: ItemWaysSave, sent: ItemWays?) {
        switch r {
        case .saved(let read):
            loads += 1 // a read started before this answer is older than it
            local = local.afterSaved(read, sent: sent)
        case .needsPassword: local.prompt = WaysPrompt()
        case .credentialLocked: local.prompt = WaysPrompt(resend: true)
        case .lockedAgain:
            local.prompt = nil
            local.notice = .lockedAgain
        case .readOnlyLocked:
            local.prompt = nil
            local.notice = .readOnlyLocked
        case .conflict:
            local.prompt = nil
            local.notice = .conflict
            load()
        case .notIncluded:
            local.prompt = nil
            local.notIncluded = true
            local.leaving = true
        case .badRequest(let message):
            local.prompt = nil
            local.refused = VaultReason.shown(message) ?? ""
        case .ownerCheck:
            local.prompt = nil
            local.ownerCheck = true
        case .alarmOpen: refuse(.credentialFrozen)
        case .passwordRefused(let f): refuse(f.kind)
        case .failed(let f):
            local.prompt = nil
            local.notice = .failed(f.kind)
        }
    }

    /// The prompt stays, empty, with the refusal.
    private func refuse(_ kind: FailureKind) {
        var p = local.prompt ?? WaysPrompt()
        p.password = ""
        p.sending = false
        p.error = kind
        local.prompt = p
    }

    public func noticeShown() { local.notice = nil }

    public func ownerCheckShown() { local.ownerCheck = false }

    public func closeWindowNow() {
        let repo = repo
        work.launch { try? await repo.closeWindowNow() }
    }

    /// TEST ONLY: returns once the work started so far has run.
    func settle() async { await work.settle() }
}
