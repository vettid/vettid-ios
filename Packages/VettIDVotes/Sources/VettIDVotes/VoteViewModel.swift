import Foundation
import Observation
import VettIDData

/// Where the screen is in a cast (ANDROID-PLAN 0.1.102 screens 2 and 3).
public enum CastStep: Equatable, Sendable { case none, confirm, password, sending }

/// The vault's evidence of a vote, in memory only, handed to the system's file exporter (IOS-PLAN §4.16 "Save the proof"):
/// the bytes are the vault's evidence unchanged; the name is the proposal's id, never the title or the choice. Its
/// description shows nothing of it.
public struct ProofFile: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let bytes: Data
    public let name: String

    public var description: String { "ProofFile(\(bytes.count) bytes)" }
    public var debugDescription: String { description }
}

/// One vote's state (screens 2 to 7). It holds the member's choice (``VoteDetail``), the credential password while the
/// prompt is open and the vault's evidence while it waits for the exporter: its description and mirror show none of it.
/// Mirrors vettid-android `VoteUiState`.
public struct VoteScreenState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var key: VoteKey
    /// The vote as the list has it now (the pair identifies it).
    public var summary: VoteSummary?
    /// The vote with its text and choices (`vote.get`); the member's choice is in it once cast. Memory only.
    public var detail: VoteDetail?
    public var serviceName = ""
    public var hint = VoteHint()
    /// The vault was asked at least once (a missing ``summary`` after that is a vote that is not there).
    public var loaded = false
    public var loadError: VoteProblem?
    public var selected: String?
    public var cast = CastStep.none
    /// The request under way was sent with the credential password (the sheet stays on its password step, busy, even when the
    /// typed password was dropped meanwhile).
    public var castWithPassword = false
    public var password = ""
    public var passwordError: VoteProblem?
    /// The end of a password backoff (`retry_after`).
    public var retryUntil: Date?
    public var castProblem: VoteProblem?
    /// The lock of the unlock window a cast opened failed: told until it is closed (**Close it now**) or the vault locks.
    public var windowNotClosed: WindowNotClosed?
    public var windowClosing = false
    public var windowCloseProblem: VoteProblem?
    /// The vault answered `already_voted`: the vote is read again and the recorded choice is told, never silently.
    public var alreadyVoted = false
    public var checking = false
    public var checkProblem: VoteProblem?
    /// What the last **Check again** came to when it was not handed to the vault: the site had nothing, or could not be reached.
    public var checkOutcome: ResultsOutcome?
    public var restoreBusy = false
    public var restoreProblem: VoteProblem?
    public var proofWarning = false
    public var proofBusy = false
    public var proofProblem: VoteProblem?
    /// The vault's evidence waits for the member to choose where to save it ("Save to Files"); never logged.
    public var proofReady = false
    public var proofSaved = false
    public var proofSaveFailed = false
    /// The proof was written in this visit: **Release** is offered from then on (the vault checks it again).
    public var proofExported = false
    public var releaseDialog = false
    public var releaseBusy = false
    public var releaseProblem: VoteProblem?
    public var released = false

    public init(key: VoteKey) { self.key = key }

    /// Whether **Cast your vote** is enabled: a choice is selected, the vault says it may be cast, nothing waits on a
    /// restore ("Is this your vote?") and no cast is under way.
    public var canCast: Bool {
        guard let summary, let selected, detail?.choices.contains(where: { $0.id == selected }) == true else { return false }
        return VoteRules.castAllowed(summary) && cast == .none
    }

    /// The label of the member's own choice (once cast), from the choices as sent.
    public var choiceLabel: String? {
        detail?.choiceID.map { id in detail?.choices.first { $0.id == id }?.label ?? id }
    }

    /// The label of the ballot the service holds, while a restore asks "Is this your vote?".
    public var restoreLabel: String? {
        detail?.serviceBallotChoiceID.map { id in detail?.choices.first { $0.id == id }?.label ?? id }
    }

    /// "Is this your vote?" is offered only when the vault named a ballot to ask about (any other unsigned ballot is a problem).
    public var restoreAsked: Bool { summary?.confirmPending == true && restoreLabel != nil }

    public var description: String { "VoteScreenState(\(key.connectionID)/\(key.proposalID), cast: \(cast))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// One vote (ANDROID-PLAN 0.1.102 to 0.1.108 §4 "Votes", screens 2 to 7): its text, the choices, the cast with its confirm
/// sheet and the unlock window prompt, the states in words, the results, **Save the proof**, **Release** and "Is this your
/// vote?". Identified by the pair (connection, proposal). Fails secure: a request that fails leaves the screen as it was
/// and says so; a cast is sent once and never retried by the app, only by the member, and never while a restore waits for
/// the member's answer. Work cut off by a lock or by the app leaving reaches here as ``CancellationError`` and is silent:
/// no error text. Mirrors vettid-android `VoteViewModel`.
@MainActor
@Observable
public final class VoteViewModel {
    @ObservationIgnored private let repo: any VotesRepository
    @ObservationIgnored private let connections: any ConnectionsRepository
    @ObservationIgnored private let ownerChecks: (any OwnerCheckRepository)?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    @ObservationIgnored private let key: VoteKey
    @ObservationIgnored private var loadJob: Task<Void, Never>?
    @ObservationIgnored private var lastSummary: VoteSummary?
    /// The evidence the vault gave, until the member saves it or leaves; only in memory.
    @ObservationIgnored private var proof: String?
    private var local: VoteScreenState

    /// [ownerChecks]: a vote refused because the daily check was due reads again by itself once a check passes. [now]: the
    /// clock (tests set it).
    public init(
        key: VoteKey, repo: any VotesRepository, connections: any ConnectionsRepository,
        ownerChecks: (any OwnerCheckRepository)? = nil, now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.key = key
        self.repo = repo
        self.connections = connections
        self.ownerChecks = ownerChecks
        self.now = now
        local = VoteScreenState(key: key)
        refresh()
        // A change of the vote (a ballot answered, a check made) reads it again: the choice and the tally appear then.
        follows.add(follow(self, read: { $0.current }, apply: { $0.onSummary($1) }))
        if ownerChecks != nil {
            follows.add(follow(self, read: { $0.ownerChecks?.ownerCheck }, apply: { $0.onOwnerCheck($1) }))
        }
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    private var current: VoteSummary? { repo.votes.first { $0.key == key } }

    public var state: VoteScreenState {
        var s = local
        let summary = current
        s.summary = summary
        s.serviceName = serviceName(connections.connections.first { $0.id == key.connectionID })
        s.hint = repo.hints[key] ?? VoteHint()
        s.windowNotClosed = repo.windowNotClosed
        return s
    }

    private func onSummary(_ now: VoteSummary?) {
        guard let now else { return }
        if let last = lastSummary, now != last { loadDetail() }
        lastSummary = now
        // "Is this your vote?" is held back while the cast sheet is up: the vault now waits on the member's answer about an
        // earlier vote, so nothing is cast and the typed password goes.
        if now.confirmPending, local.cast == .confirm || local.cast == .password { dismissCast() }
        if now.check?.state == .gaveUp {
            let repo = repo
            let key = key
            work.launch { await repo.diagnoseGaveUp(key) }
        }
    }

    private func onOwnerCheck(_ v: OwnerCheckView?) {
        guard v?.state == .ok, local.loadError?.kind == .ownerCheckRequired else { return }
        refresh()
    }

    /// On opening, on Try again, and on a return to the screen: the list, the vote, and the public site's copy of it.
    public func refresh() {
        local.loadError = nil
        loadJob?.cancel()
        let repo = repo
        let key = key
        loadJob = work.launch { [weak self] in
            do {
                try await repo.refresh()
            } catch where isSilent(error) {
                return
            } catch {
                self?.local.loadError = VoteProblem(error)
                self?.local.loaded = true
                return
            }
            // The vault checks closed and closing before it checks for a repeat of the same choice: a retry may have been
            // refused while the vote was recorded. A vote that holds a ballot is not "not sent".
            if self?.current?.ballot != nil { self?.local.castProblem = nil }
            await self?.readDetail()
            // The vote's own documents are read from the public site when its screen opens, so that the vault can compare
            // it with the public copy. Best effort: a failure, and a lock or the app leaving (CancellationError), are silent.
            do { try await repo.siteCheck(key) } catch {}
        }
    }

    private func loadDetail() {
        work.launch { [weak self] in await self?.readDetail() }
    }

    private func readDetail() async {
        do {
            let d = try await repo.get(key)
            local.detail = d
            local.loaded = true
            local.loadError = nil
            local.selected = local.selected.flatMap { s in d.choices.contains { $0.id == s } ? s : nil }
        } catch where isSilent(error) {
            // Cut off: the screen shows what it had.
        } catch {
            local.loaded = true
            if local.detail == nil { local.loadError = VoteProblem(error) }
        }
    }

    // MARK: Casting

    public func select(_ choiceID: String) {
        guard local.cast == .none else { return }
        local.selected = choiceID
        local.castProblem = nil
        local.alreadyVoted = false
    }

    /// The vault's word as the list has it now (not as the screen last drew it), a choice in the list sent, and nothing
    /// waiting on a restore: the only gate of a cast (the vault checks again).
    private func canCastNow() -> Bool {
        guard let summary = current, let selected = local.selected, local.detail?.choices.contains(where: { $0.id == selected }) == true
        else { return false }
        return VoteRules.castAllowed(summary)
    }

    /// **Cast your vote**: the confirm sheet, with the fixed disclosure. Nothing is sent.
    public func askCast() {
        guard local.cast == .none, canCastNow() else { return }
        local.cast = .confirm
        local.castProblem = nil
    }

    public func dismissCast() {
        // Not while the request is on its way: it is not undone by closing the sheet.
        guard local.cast != .sending else { return }
        local.cast = .none
        local.password = ""
        local.passwordError = nil
    }

    /// **Cast vote** in the sheet: at once when the unlock window is open, else the credential password is asked for first.
    public func confirmCast() {
        guard local.cast == .confirm, canCastNow() else { return }
        if repo.windowOpen() {
            send(nil)
        } else {
            local.cast = .password
            local.passwordError = nil
        }
    }

    public func setPassword(_ v: String) {
        local.password = v
        local.passwordError = nil
    }

    /// **Confirm** in the password prompt.
    public func submitPassword() {
        guard local.cast == .password, !local.password.isEmpty, canCastNow() else { return }
        if let until = local.retryUntil, until > now() { return }
        send(local.password)
    }

    /// Sent once: the request is never repeated by the app after an answer or a failure; only the member can cast again.
    private func send(_ password: String?) {
        guard let choice = local.selected else { return }
        local.cast = .sending
        local.castWithPassword = password != nil
        local.castProblem = nil
        local.passwordError = nil
        let repo = repo
        let key = key
        work.launch { [weak self] in
            do {
                _ = try await repo.cast(key, choiceID: choice, password: password)
                // The password is held only while the request runs.
                self?.local.cast = .none
                self?.local.castWithPassword = false
                self?.local.password = ""
                self?.local.selected = nil
                self?.local.retryUntil = nil
                self?.loadDetail()
            } catch where isSilent(error) {
                // A lock or the app leaving cut the request off: silent. The vote may have been sent, so it is read again.
                self?.local.cast = .none
                self?.local.castWithPassword = false
                self?.local.password = ""
                self?.refresh()
            } catch {
                self?.onCastFailure(VoteProblem(error))
            }
        }
    }

    private func onCastFailure(_ p: VoteProblem) {
        local.castWithPassword = false
        switch p.kind {
        case .credentialLocked:
            // The window was closed after all: the prompt again (the member confirms; the app sends nothing by itself).
            local.cast = .password
            local.password = ""
            local.passwordError = nil
        case .badPassword, .backoff, .credentialFrozen, .rotationRequired:
            local.cast = .password
            local.password = ""
            local.passwordError = p
            local.retryUntil = p.kind == .backoff ? now().addingTimeInterval(TimeInterval(p.retryAfterSeconds)) : nil
        default:
            // A refusal of the vault (closed, closing, already voted…) or no answer: the screen says so and reads the vote
            // again. `already_voted`: not a failure but a notice, with the choice the re-read ballot holds.
            let voted = p.code == "already_voted"
            local.cast = .none
            local.password = ""
            local.castProblem = voted ? nil : p
            local.alreadyVoted = voted
        }
        // Whatever failed, the vote is read again, after the screen's state is set: a cast whose answer was lost may have
        // been sent, and the list says so.
        refresh()
    }

    public func dismissAlreadyVoted() { local.alreadyVoted = false }

    public func dismissCastProblem() { local.castProblem = nil }

    /// The app went to the background: the typed password goes (IOS-PLAN §6.3).
    public func forgetSecrets() {
        local.password = ""
    }

    /// The screen left: the password goes, and so does evidence that was not saved (it is the member's own, and nobody's
    /// else to keep).
    public func leave() {
        local.password = ""
        proof = nil
        local.proofReady = false
    }

    // MARK: The unlock window

    /// **Close it now** on the notice of a lock that failed: the notice goes only when this went through.
    public func closeWindowNow() {
        guard !local.windowClosing else { return }
        local.windowClosing = true
        local.windowCloseProblem = nil
        let repo = repo
        work.launch { [weak self] in
            do {
                try await repo.closeWindowNow()
                self?.local.windowClosing = false
            } catch where isSilent(error) {
                self?.local.windowClosing = false
            } catch {
                self?.local.windowClosing = false
                self?.local.windowCloseProblem = VoteProblem(error)
            }
        }
    }

    // MARK: The check

    /// Check with the service / Check again (`vote.check`, and the results for a closed vote).
    public func checkWithService() {
        guard let s = current, !local.checking else { return }
        local.checking = true
        local.checkProblem = nil
        local.checkOutcome = nil
        let repo = repo
        let key = key
        work.launch { [weak self] in
            do {
                // A closed vote: the results from the site, handed to the vault; else the service is asked (`vote.check`).
                var out: ResultsOutcome?
                if s.closed {
                    out = try await repo.checkResults(key)
                } else {
                    try await repo.check(key)
                }
                self?.local.checking = false
                self?.local.checkOutcome = out
            } catch where isSilent(error) {
                // A lock or the app leaving cut the check off: silent, no outcome.
                self?.local.checking = false
            } catch {
                self?.local.checking = false
                self?.local.checkProblem = VoteProblem(error)
            }
        }
    }

    public func dismissCheckProblem() { local.checkProblem = nil }

    // MARK: Is this your vote?

    public func answerRestore(mine: Bool) {
        guard !local.restoreBusy else { return }
        local.restoreBusy = true
        local.restoreProblem = nil
        let repo = repo
        let key = key
        work.launch { [weak self] in
            do {
                let state = try await repo.confirm(key, mine: mine)
                self?.local.restoreBusy = false
                if state == .recorded || state == .disputed { self?.loadDetail() }
            } catch where isSilent(error) {
                self?.local.restoreBusy = false
            } catch {
                self?.local.restoreBusy = false
                self?.local.restoreProblem = VoteProblem(error)
            }
        }
    }

    // MARK: The proof

    /// **Save the proof**: the warning first.
    public func askProof() {
        // Evidence from an earlier Save that was never written goes: a second Save always opens the exporter again.
        proof = nil
        local.proofReady = false
        local.proofWarning = true
        local.proofProblem = nil
        local.proofSaved = false
        local.proofSaveFailed = false
    }

    public func dismissProofWarning() { local.proofWarning = false }

    /// The warning was accepted: the vault's evidence is fetched, then the screen offers "Save to Files". Nothing is
    /// written until the member chooses where, in the system's exporter.
    public func fetchProof() {
        guard !local.proofBusy else { return }
        proof = nil
        local.proofReady = false
        local.proofWarning = false
        local.proofBusy = true
        local.proofProblem = nil
        let repo = repo
        let key = key
        work.launch { [weak self] in
            do {
                let text = try await repo.evidence(key)
                self?.proof = text
                self?.local.proofBusy = false
                self?.local.proofReady = true
            } catch where isSilent(error) {
                self?.local.proofBusy = false
            } catch {
                self?.local.proofBusy = false
                self?.local.proofProblem = VoteProblem(error)
            }
        }
    }

    /// The file offered to the exporter: while the evidence waits there, else nil.
    public var proofFile: ProofFile? {
        guard local.proofReady, let proof else { return nil }
        return ProofFile(bytes: Data(proof.utf8), name: proofFileName)
    }

    /// The file name offered to "Save to Files": the proposal's id, never the title or the choice. (Chosen; not in the
    /// spec: only letters, digits, `-` and `_` of the id are kept, so that a file name never holds anything else.)
    public var proofFileName: String {
        let kept = key.proposalID.unicodeScalars.filter { c in
            c.isASCII && (c.properties.isAlphabetic || ("0"..."9").contains(c) || c == "-" || c == "_")
        }
        let id = String(kept)
        return "vettid-vote-\(id.isEmpty ? "proof" : id).json"
    }

    /// The exporter's answer: [saved] true once the file was written where the member chose; false when it was cancelled or
    /// dismissed. The evidence is dropped either way.
    public func proofExporterAnswered(saved: Bool) {
        proof = nil
        local.proofReady = false
        guard saved else { return }
        local.proofSaved = true
        local.proofSaveFailed = false
        local.proofExported = true
    }

    /// The exporter could not write the file: "The proof could not be saved. Try again."; the evidence is dropped.
    public func proofExporterFailed() {
        proof = nil
        local.proofReady = false
        local.proofSaved = false
        local.proofSaveFailed = true
    }

    /// The saved / failed message was shown.
    public func proofShown() {
        local.proofSaved = false
        local.proofSaveFailed = false
    }

    // MARK: Release

    /// **Release**: offered only after the proof was saved (the vault checks it again, `evidence_not_exported`).
    public func askRelease() {
        guard local.proofExported, !local.released else { return }
        local.releaseDialog = true
    }

    public func dismissRelease() {
        local.releaseDialog = false
        local.releaseProblem = nil
    }

    /// Sends `vote.release` with [pin] (taken from the in-app keypad, IOS-PLAN §6.5); nothing before the proof was saved.
    public func release(pin: String) {
        guard local.proofExported, !local.releaseBusy, !pin.isEmpty else { return }
        local.releaseBusy = true
        local.releaseProblem = nil
        let repo = repo
        let key = key
        work.launch { [weak self] in
            do {
                try await repo.release(key, pin: pin)
                self?.local.releaseBusy = false
                self?.local.releaseDialog = false
                self?.local.released = true
            } catch where isSilent(error) {
                self?.local.releaseBusy = false
            } catch {
                self?.local.releaseBusy = false
                self?.local.releaseProblem = VoteProblem(error)
            }
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
