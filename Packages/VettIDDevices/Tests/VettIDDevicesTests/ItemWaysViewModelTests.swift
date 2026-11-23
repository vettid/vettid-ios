import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDDevices

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// ANDROID-PLAN 0.1.137 AA7: the item's page, its draft, its confirmations and its saves. Mirrors vettid-android
/// `ItemWaysViewModelTest` (without AA9's folders).
@MainActor
@Suite struct ItemWaysViewModelTests {
    let repo = FakeItemWays()
    let devices = Samples.fake([DeviceInfo(id: "a1", kind: "agent", name: "Claude")])
    let items = FakeItems()
    let sha = String(repeating: "ab", count: 32)

    init() {
        items.add(ItemDetail(itemID: "i1", version: 1, name: "GitHub token", category: "api_key", sensitivity: .secret))
    }

    func vm() async -> ItemWaysViewModel {
        let m = ItemWaysViewModel(agentID: "a1", itemID: "i1", repo: repo, devices: devices, items: items)
        await m.settle()
        return m
    }

    /// The events reach the model through its follower: let it run, then the work it started.
    func settled(_ m: ItemWaysViewModel) async -> ItemWaysState {
        for _ in 0..<20 { await Task.yield() }
        await m.settle()
        return m.state
    }

    /// Lets the main actor run what is runnable, without waiting for work held at a gate.
    func pump() async { for _ in 0..<100 { await Task.yield() } }

    func event(_ m: ItemWaysViewModel, _ kind: ItemWaysEvent.Kind) async {
        repo.fireEvent(kind)
        await pump()
    }

    func item(_ version: Int64?, _ agent: String = "a1", _ item: String = "i1") -> ItemWaysEvent.Kind {
        .item(agentID: agent, itemID: item, version: version, deleted: version == nil)
    }

    @Test func opensWithTheVaultsSettingsAndNames() async {
        let m = await vm()
        let s = m.state
        #expect(s.agentName.contains("Claude"))
        #expect(s.itemName == "GitHub token" && s.shownItemName == AccountNames.isolate("GitHub token"))
        #expect(s.draft?.ways == [.use])
        #expect(!s.dirty && !s.canSave && !s.holdsInput)
    }

    /// The reveal switch shows the history warning before it turns on; Cancel leaves it off; off asks nothing.
    @Test func revealAsksFirstAndCancelLeavesItOff() async {
        let m = await vm()
        m.setReveal(true)
        #expect(m.state.confirm == .revealOn)
        #expect(m.state.draft?.ways.contains(.reveal) == false)
        m.dismissConfirm()
        #expect(m.state.draft?.ways.contains(.reveal) == false)
        m.setReveal(true)
        m.confirm()
        #expect(m.state.draft?.ways.contains(.reveal) == true)
        m.setReveal(false)
        #expect(m.state.confirm == nil)
        #expect(m.state.draft?.ways.contains(.reveal) == false)
    }

    /// A widening asks for the password; the prompt's request is the same save with it; the vault's answer is shown.
    @Test func aWideningSaveGoesThroughThePrompt() async {
        repo.answers = [.needsPassword]
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        #expect(m.state.canSave && m.state.holdsInput)
        m.save()
        await m.settle()
        #expect(m.state.prompt != nil)
        m.setPassword("pw")
        m.submitPassword()
        await m.settle()
        #expect(repo.saves.map(\.password) == [nil, "pw"])
        #expect(m.state.prompt == nil)
        #expect(m.state.notice == .saved)
        #expect(!m.state.dirty)
        #expect(m.state.read?.ways?.ways.contains(.reveal) == true)
    }

    /// `credential_locked` after a save judged narrowing: the prompt, and one resend marked as such.
    @Test func credentialLockedPromptsAndResendsOnce() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#
        repo.answers = [.credentialLocked, .lockedAgain]
        let m = await vm()
        m.setReveal(false)
        m.save()
        await m.settle()
        #expect(m.state.prompt?.resend == true)
        m.setPassword("pw")
        m.submitPassword()
        await m.settle()
        #expect(repo.saves.map(\.password) == [nil, "pw"] && repo.saves.map(\.resent) == [false, true])
        #expect(m.state.notice == .lockedAgain)
        #expect(m.state.prompt == nil)
    }

    /// A widening's `credential_locked`: the prompt again, and the same save with the new password sent once more.
    @Test func aWideningLockedPromptsAndResendsOnce() async {
        repo.answers = [.needsPassword, .credentialLocked]
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        m.setPassword("pw")
        m.submitPassword()
        await m.settle()
        #expect(m.state.prompt?.resend == true)
        #expect(m.state.prompt?.password == "")
        m.setPassword("pw2")
        m.submitPassword()
        await m.settle()
        #expect(repo.saves.map(\.password) == [nil, "pw", "pw2"] && repo.saves.map(\.resent) == [false, false, true])
        #expect(m.state.notice == .saved)
        #expect(m.state.prompt == nil)
        #expect(Set(repo.saves.map { $0.next.setBody() }).count == 1)
    }

    /// The page resends once only: a second `credential_locked`, whatever the repository says, is "locked again".
    @Test func aSecondCredentialLockedIsNotPromptedAgain() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#
        repo.answers = [.credentialLocked, .credentialLocked]
        let m = await vm()
        m.setReveal(false)
        m.save()
        await m.settle()
        m.setPassword("pw")
        m.submitPassword()
        await m.settle()
        #expect(repo.saves.count == 2)
        #expect(m.state.prompt == nil)
        #expect(m.state.notice == .lockedAgain)
        m.submitPassword()
        await m.settle()
        #expect(repo.saves.count == 2, "nothing more sent")
    }

    @Test func aConflictReloadsAndNotFoundLeaves() async {
        repo.answers = [.conflict]
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        #expect(m.state.notice == .conflict)
        #expect(repo.reads == 2)
        #expect(!m.state.dirty)
        repo.answers = [.notIncluded]
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        #expect(m.state.notIncluded && m.state.leaving)
        #expect(!m.state.canSave)
    }

    /// AA7 "Saving" (0.1.138): a message the vault gave that can't be shown is the fallback; an edit or a save clears it.
    @Test func aRefusalWithoutAShowableMessageIsTheFallback() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#
        repo.answers = [.badRequest("")]
        let m = await vm()
        m.setReveal(false)
        m.save()
        await m.settle()
        #expect(m.state.refused == "")
        repo.answers = [.badRequest("run: a\tb")]
        m.save()
        await m.settle()
        #expect(m.state.refused == "", "a control character is not shown")
        m.save()
        await m.settle()
        #expect(m.state.notice == .saved)
        #expect(m.state.refused == nil, "a save that went through clears it")
        repo.answers = [.badRequest("")]
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        #expect(m.state.refused == "")
        m.setReveal(false)
        #expect(m.state.refused == nil, "an edit clears it")
    }

    @Test func eachAnswerHasItsNotice() async {
        repo.answers = [.badRequest("program: refused name")]
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        #expect(m.state.refused == "program: refused name")
        #expect(m.state.notice == nil, "a card, not a passing notice")
        #expect(m.state.dirty, "the draft is kept")
        repo.answers = [.needsPassword, .alarmOpen]
        m.save()
        await m.settle()
        m.setPassword("pw")
        m.submitPassword()
        await m.settle()
        #expect(m.state.prompt?.alarm == true, "the alarm stays on the prompt")
        m.dismissPrompt()
        repo.answers = [.ownerCheck]
        m.save()
        await m.settle()
        #expect(m.state.ownerCheck)
    }

    @Test func aWrongPasswordStaysOnThePromptAndAFailureIsANotice() async {
        repo.answers = [.needsPassword, .passwordRefused(VaultFailure(.badPassword))]
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        m.setPassword("pw")
        m.submitPassword()
        await m.settle()
        #expect(m.state.prompt?.error == .badPassword && m.state.prompt?.password == "" && m.state.prompt?.sending == false)
        m.setPassword("x")
        #expect(m.state.prompt?.error == nil, "typing again clears the refusal")
        m.dismissPrompt()
        repo.answers = [.failed(VaultFailure(.network))]
        m.save()
        await m.settle()
        #expect(m.state.notice == .failed(.network))
        #expect(m.state.prompt == nil)
    }

    /// Run settings: add (with each refusal), the program's page, variables, Ask me before each run, removing the last.
    @Test func programsAndTheirSettings() async {
        let m = await vm()
        m.setRun(true)
        #expect(m.state.draft?.run?.each == true)
        m.setEach(false) // with no program it stays on: the switch is disabled, and the view model refuses it too
        #expect(m.state.confirm == nil)
        m.setProgramInput("bin/git")
        m.addProgram()
        #expect(m.state.programProblem == .notPathOrName)
        m.setProgramInput("/usr/bin/git")
        m.addProgram()
        m.setProgramInput("GIT")
        m.addProgram()
        #expect(m.state.programProblem == .duplicate)
        m.setProgramInput("gh")
        m.addProgram()
        #expect(m.state.draft?.run?.programs.map(\.program) == ["/usr/bin/git", "gh"])
        m.openProgram(0)
        m.setVariableInput("lower")
        m.addVariable()
        #expect(m.state.variableProblem != nil)
        m.setVariableInput("GH_HOST")
        m.addVariable()
        #expect(m.state.draft?.run?.programs[0].env == ["GH_HOST"])
        // A name already listed is not added twice; the field empties as after any add.
        m.setVariableInput("GH_HOST")
        m.addVariable()
        #expect(m.state.draft?.run?.programs[0].env == ["GH_HOST"])
        #expect(m.state.variableInput == "")
        #expect(m.state.variableProblem == nil)
        m.removeVariable("GH_HOST")
        #expect(m.state.draft?.run?.programs[0].env.isEmpty == true)
        // Removing a program while another stays asks nothing.
        m.removeProgram(0)
        #expect(m.state.confirm == nil)
        #expect(m.state.draft?.run?.programs.map(\.program) == ["gh"])
        m.setEach(false)
        m.confirm()
        #expect(m.state.draft?.run?.each == false)
        // Removing the last asks first, and emptying the list turns Ask me before each run back on.
        m.removeProgram(0)
        #expect(m.state.confirm == .removeLastProgram(0))
        m.confirm()
        #expect(m.state.draft?.run?.programs.isEmpty == true)
        #expect(m.state.draft?.run?.each == true)
    }

    /// Forget fingerprint asks first, then shows it is forgotten until Save, which sends no pin; editing forgets it too.
    @Test func fingerprints() async throws {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","run"],"run":{"programs":[{"program":"git","sha256":"\#(sha)","path":"/usr/bin/git","env":["GH_HOST"]}],"each":true}}"#
        let m = await vm()
        m.forgetPin(0)
        #expect(m.state.confirm == .forgetPin(0))
        m.confirm()
        let p = try #require(m.state.draft?.run?.programs.first)
        #expect(p.sha256 == nil)
        #expect(m.state.pinForgotten(p))
        m.save()
        await m.settle()
        #expect(repo.saves.first?.next.run?.programs[0].sha256 == nil)
        // Changing the program's text: removing it and adding another, its variables kept, no pin.
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":3,"ways":["use","run"],"run":{"programs":[{"program":"git","sha256":"\#(sha)","path":"/usr/bin/git","env":["GH_HOST"]}],"each":true}}"#
        m.load()
        await m.settle()
        m.openProgram(0)
        m.setEditInput("bin/x")
        #expect(!m.closeProgram())
        #expect(m.state.editProblem == .notPathOrName)
        m.setEditInput("/usr/local/bin/git")
        #expect(m.closeProgram())
        let q = try #require(m.state.draft?.run?.programs.first)
        #expect(q.program == "/usr/local/bin/git" && q.sha256 == nil && q.env == ["GH_HOST"])
    }

    /// The API switch: defaults filled in, Add a host opened, no save until a host is there; each refusal; the last host stays.
    @Test func apiSettings() async {
        let m = await vm()
        m.setProxy(true)
        #expect(m.state.addingHost)
        #expect(m.state.draft?.proxy?.header == "Authorization")
        #expect(m.state.draft?.proxy?.prefix == "Bearer ")
        #expect(!m.state.canSave, "proxy needs a host")
        m.setHostInput("10.0.0.1")
        m.addHost()
        #expect(m.state.hostProblem == .ipAddress)
        m.setHostInput(" API.Example.com ")
        m.addHost()
        #expect(m.state.draft?.proxy?.hosts == ["api.example.com"])
        #expect(m.state.canSave)
        m.removeHost("api.example.com")
        #expect(m.state.draft?.proxy?.hosts == ["api.example.com"])
        m.setHeader("Host")
        #expect(!m.state.canSave)
        m.setHeader("X-Api-Key")
        m.setPrefix(String(repeating: "x", count: 33))
        #expect(!m.state.canSave)
        m.setPrefix("Token ")
        #expect(m.state.canSave)
        // Turning it off asks first.
        m.setProxy(false)
        #expect(m.state.confirm == .proxyOff)
        m.confirm()
        #expect(m.state.draft?.proxy == nil)
    }

    /// A read-only page offers only to turn a whole way off, saved at once, with its confirmation.
    @Test func aReadOnlyPageTurnsWaysOff() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","run","reveal"],"run":{"programs":[],"each":true,"x":1}}"#
        let m = await vm()
        #expect(m.state.readOnly)
        #expect(m.state.draft == nil)
        m.setRun(false)
        #expect(m.state.confirm == .runOff)
        m.confirm()
        await m.settle()
        m.setReveal(false)
        await m.settle()
        #expect(repo.offs == ["run", "reveal"])
        #expect(repo.saves.isEmpty)
        #expect(m.state.canTurnOff)
    }

    /// A read-only turn-off the vault answers with `credential_locked` opens no prompt: it is said, nothing resent.
    @Test func aReadOnlyTurnOffThatIsLockedOpensNoPrompt() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","reveal"],"x":1}"#
        repo.answers = [.readOnlyLocked]
        let m = await vm()
        m.setReveal(false)
        await m.settle()
        #expect(m.state.prompt == nil)
        #expect(m.state.notice == .readOnlyLocked)
        #expect(repo.offs == ["reveal"])
    }

    /// Another agent's item, or an answer that did not read strictly: no turn-off can be sent, so none is offered.
    @Test func aReadOnlyPageThatCannotTurnOffSaysSo() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","reveal"],"x":1,"x":2}"#
        let m = await vm()
        #expect(m.state.readOnly)
        #expect(!m.state.canTurnOff)
    }

    /// Turning Ask me before each run off asks first, with a program; without one it is refused.
    @Test func askMeOffAsksFirst() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","run"],"run":{"programs":[{"program":"gh","env":[]}],"each":true}}"#
        let m = await vm()
        m.setEach(false)
        #expect(m.state.confirm == .eachOff)
        #expect(m.state.draft?.run?.each == true, "nothing changed before the answer")
        m.confirm()
        #expect(m.state.draft?.run?.each == false)
    }

    /// A read again on returning that finds the item no longer included closes the password sheet.
    @Test func aShowTheCurrentOnesReadThatFindsTheItemGoneClosesThePrompt() async {
        repo.answers = [.needsPassword]
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        #expect(m.state.prompt != nil)
        repo.current = nil
        m.load()
        await m.settle()
        #expect(m.state.notIncluded)
        #expect(m.state.prompt == nil)
    }

    /// Back on the page with nothing unsaved, the settings are read again (this phone's own approval sends it no event).
    @Test func returningToTheCleanPageReadsAgain() async {
        let m = await vm()
        #expect(repo.reads == 1)
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","reveal"]}"#
        m.returned()
        await m.settle()
        #expect(repo.reads == 2)
        #expect(m.state.read?.ways?.version == 2)
        m.setReveal(false)
        m.returned()
        await m.settle()
        #expect(repo.reads == 2, "unsaved changes: not read")
    }

    /// Try again after a failed read keeps what the member changed.
    @Test func tryAgainKeepsTheDraft() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#
        let m = await vm()
        m.setReveal(false)
        repo.failRead = VaultFailure(.network)
        await event(m, item(2))
        m.retry() // a read that fails first: the card
        await m.settle()
        #expect(m.state.loadError != nil)
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","reveal"]}"#
        m.retry()
        await m.settle()
        #expect(m.state.draft?.ways.contains(.reveal) == false)
        #expect(m.state.changedElsewhere)
    }

    /// An event whose `version` does not read is not a deletion: the settings are read again.
    @Test func aMalformedEventVersionReadsAgain() async {
        let m = await vm()
        await event(m, .item(agentID: "a1", itemID: "i1", version: nil, deleted: false))
        #expect(!m.state.notIncluded)
        #expect(repo.reads == 2)
    }

    /// The vault answering `folders: []` to a save that sent none is the same settings: no "changed elsewhere".
    @Test func anEmptyFoldersAnswerIsTheSameSave() async throws {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","run","reveal"],"run":{"programs":[{"program":"gh","env":[]}],"each":true}}"#
        let gate = TestDeferred<Void>()
        repo.saveGate = gate
        repo.answers = [.saved(try #require(ItemWaysRules.one(Array(#"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","run"],"run":{"programs":[{"program":"gh","env":[]}],"each":true,"folders":[]}}"#.utf8))))]
        let m = await vm()
        m.setReveal(false)
        m.save()
        await pump()
        m.setEach(false)
        m.confirm()
        gate.complete()
        await m.settle()
        #expect(!m.state.changedElsewhere)
        #expect(m.state.draft?.version == 2)
    }

    /// `leash.item.changed` while open: reread when nothing is edited; kept with the notice when it is; deleted settings said.
    @Test func changesFromAnotherDevice() async {
        let m = await vm()
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","reveal"]}"#
        await event(m, item(2))
        #expect(m.state.read?.ways?.version == 2)
        m.setRun(true)
        await event(m, item(3))
        #expect(m.state.changedElsewhere && m.state.dirty)
        let reads = repo.reads
        await event(m, item(3, "a1", "other"))
        #expect(repo.reads == reads, "another item's change reads nothing")
        #expect(m.state.dirty)
        await event(m, item(nil))
        #expect(m.state.notIncluded)
        #expect(!m.state.canSave)
    }
}
// swiftlint:enable line_length
