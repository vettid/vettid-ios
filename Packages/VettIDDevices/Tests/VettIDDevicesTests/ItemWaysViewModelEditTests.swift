import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDDevices

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The second half of ``ItemWaysViewModelTests``: edits, events and reads that cross, a lock, and what is held.
extension ItemWaysViewModelTests {
    /// A save's answer keeps what the member changed while it was out (the draft is not the one sent).
    @Test func anEditDuringASaveIsKept() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal","proxy"],"proxy":{"hosts":["a.example.com","b.example.com"],"header":"Authorization","prefix":"Bearer "}}"#
        let gate = TestDeferred<Void>()
        repo.saveGate = gate
        let m = await vm()
        m.removeHost("b.example.com")
        m.save()
        await pump()
        m.setHeader("X-Api-Key")
        gate.complete()
        await m.settle()
        #expect(m.state.notice == .saved)
        #expect(m.state.draft?.proxy?.header == "X-Api-Key")
        #expect(m.state.draft?.proxy?.hosts == ["a.example.com"])
        #expect(m.state.dirty, "still to be saved")
    }

    /// The kept edit moves onto the saved version, so its own save goes out at once, at that version, with no prompt.
    @Test func aKeptEditSavesAtTheNewVersion() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal","proxy"],"proxy":{"hosts":["a.example.com","b.example.com"],"header":"Authorization","prefix":"Bearer "}}"#
        repo.bump = true
        let gate = TestDeferred<Void>()
        repo.saveGate = gate
        let m = await vm()
        m.removeHost("b.example.com")
        m.save()
        await pump()
        m.setReveal(false)
        gate.complete()
        await m.settle()
        #expect(m.state.read?.ways?.version == 2)
        #expect(m.state.draft?.version == 2)
        #expect(!m.state.changedElsewhere)
        m.save()
        await m.settle()
        #expect(repo.saves.map(\.next.version) == [1, 2])
        #expect(m.state.prompt == nil, "a narrowing: no prompt")
        #expect(m.state.read?.ways?.version == 3)
    }

    /// The vault saved something other than what was sent: the edit stays on its own read, changed elsewhere.
    @Test func aKeptEditOverADifferentSaveIsChangedElsewhere() async throws {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#
        let gate = TestDeferred<Void>()
        repo.saveGate = gate
        repo.answers = [.saved(try #require(ItemWaysRules.one(Array(#"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","run"],"run":{"programs":[{"program":"gh","env":[]}],"each":true}}"#.utf8))))]
        let m = await vm()
        m.setReveal(false)
        m.save()
        await pump()
        m.setReveal(true)
        m.confirm()
        gate.complete()
        await m.settle()
        #expect(m.state.changedElsewhere)
        #expect(m.state.read?.ways?.version == 1, "the read the edit was made from")
        #expect(m.state.draft?.ways.contains(.reveal) == true)
    }

    /// A re-read that started before a save answers after it: it is not applied over the saved read.
    @Test func aReadOlderThanASaveIsDropped() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#
        repo.bump = true
        let m = await vm()
        let slow = TestDeferred<String?>()
        repo.readGates = [slow]
        await event(m, item(2))
        m.setReveal(false)
        m.save()
        await pump()
        #expect(m.state.read?.ways?.version == 2)
        slow.complete(#"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#)
        await m.settle()
        #expect(m.state.read?.ways?.version == 2)
        #expect(!m.state.changedElsewhere)
    }

    /// An event's re-read keeps an edit made while it was out; of two reads only the latest is applied.
    @Test func anEventsReadKeepsAnEditAndOnlyTheLatestApplies() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#
        let m = await vm()
        let slow = TestDeferred<String?>()
        repo.readGates = [slow]
        await event(m, item(2))
        m.setReveal(false)
        slow.complete(#"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","reveal"]}"#)
        await m.settle()
        #expect(m.state.read?.ways?.version == 1, "the edit stays on its own read")
        #expect(m.state.draft?.ways.contains(.reveal) == false, "the edit is kept")
        #expect(m.state.changedElsewhere)
        // Show the current ones (a forced read) twice; the first answers last and is not applied.
        let older = TestDeferred<String?>()
        let newer = TestDeferred<String?>()
        repo.readGates = [older, newer]
        m.load()
        m.load()
        await Task.yield()
        newer.complete(#"{"agent_id":"a1","item_id":"i1","version":4,"ways":["use"]}"#)
        await pump()
        older.complete(#"{"agent_id":"a1","item_id":"i1","version":3,"ways":["use","reveal"]}"#)
        await m.settle()
        #expect(m.state.read?.ways?.version == 4)
        #expect(m.state.draft?.ways == [.use])
        #expect(!m.state.changedElsewhere)
    }

    /// No `version` closes the prompt and saves nothing; included again, the page is back.
    @Test func notIncludedSavesNothingUntilIncludedAgain() async {
        repo.answers = [.needsPassword]
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        m.setPassword("pw")
        await event(m, item(nil))
        #expect(m.state.prompt == nil)
        m.submitPassword()
        m.save()
        await m.settle()
        #expect(repo.saves.count == 1, "only the first save went out")
        m.load()
        await m.settle()
        #expect(!m.state.notIncluded)
        m.setReveal(true)
        m.confirm()
        #expect(m.state.canSave, "the page saves again")
    }

    /// A changed program text counts as a change; Back with a refused text stays once, then leaves without it.
    @Test func aTypedProgramTextIsAChangeAndBackDropsARefusedOne() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","run"],"run":{"programs":[{"program":"gh","env":[]},{"program":"git","env":[]}],"each":true}}"#
        let m = await vm()
        m.openProgram(0)
        m.setEditInput("curl")
        #expect(m.state.canSave && m.state.holdsInput)
        m.save()
        await m.settle()
        #expect(repo.saves.isEmpty, "Save applies the text first, shown on the page")
        #expect(m.state.draft?.run?.programs.map(\.program) == ["curl", "git"] && !m.state.editPending)
        m.save()
        await m.settle()
        #expect(repo.saves.first?.next.run?.programs.map(\.program) == ["curl", "git"])
        m.openProgram(0)
        m.setEditInput("GIT")
        #expect(!m.closeProgram(), "refused on Back")
        #expect(m.state.editProblem == .duplicate)
        #expect(m.closeProgram(), "Back again leaves")
        #expect(m.state.openProgram == nil)
        #expect(!m.state.dirty)
    }

    /// Try again with only a typed program text: kept, with its open page.
    @Test func tryAgainKeepsATypedProgramText() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","run"],"run":{"programs":[{"program":"gh","env":[]}],"each":true}}"#
        let m = await vm()
        m.openProgram(0)
        m.setEditInput("curl")
        m.retry()
        await m.settle()
        #expect(m.state.openProgram == 0)
        #expect(m.state.editInput == "curl")
    }

    /// A re-read that answers the same version while the member began typing: the read is taken in, nothing else touched.
    @Test func aSameVersionReReadTouchesNothingTheMemberHolds() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","run"],"run":{"programs":[{"program":"gh","env":[]}],"each":true}}"#
        let m = await vm()
        let slow = TestDeferred<String?>()
        repo.readGates = [slow]
        m.returned()
        await Task.yield()
        m.openProgram(0)
        m.setEditInput("g")
        slow.complete(#"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","run"],"run":{"programs":[{"program":"gh","sha256":"\#(sha)","path":"/usr/bin/gh","env":[]}],"each":true}}"#)
        await m.settle()
        #expect(m.state.openProgram == 0)
        #expect(m.state.editInput == "g")
        #expect(!m.state.changedElsewhere)
        #expect(m.state.read?.ways?.run?.programs[0].sha256 == sha, "the recorded pin is taken in")
        #expect(m.state.draft?.run?.programs[0].sha256 == sha, "a clean draft follows it")
    }

    /// A new version while the member holds anything keeps it all, with the notice.
    @Test func aNewVersionWhileBusyKeepsEverything() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#
        let m = await vm()
        m.setReveal(true) // the warning is open: nothing changed yet
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use"]}"#
        await event(m, item(2))
        #expect(m.state.confirm == .revealOn)
        #expect(m.state.changedElsewhere)
    }

    /// Coming back while a dialog, a program page or typed text is open reads nothing.
    @Test func returningWhileSomethingIsOpenReadsNothing() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","proxy"],"proxy":{"hosts":["a.example.com"],"header":"Authorization","prefix":""}}"#
        let m = await vm()
        m.setHostInput("b.exa")
        m.returned()
        await m.settle()
        #expect(repo.reads == 1)
        m.setHostInput("")
        m.setReveal(true)
        m.returned()
        await m.settle()
        #expect(repo.reads == 1)
        m.dismissConfirm()
        m.returned()
        await m.settle()
        #expect(repo.reads == 2)
    }

    /// The same version with a new pin while the draft holds a change: kept on its read, with the notice; no false "forgotten".
    @Test func aSameVersionPinWithAChangedDraftIsChangedElsewhere() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","run","reveal"],"run":{"programs":[{"program":"gh","env":[]}],"each":true}}"#
        let m = await vm()
        m.setReveal(false)
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","run","reveal"],"run":{"programs":[{"program":"gh","sha256":"\#(sha)","path":"/usr/bin/gh","env":[]}],"each":true}}"#
        m.retry()
        await m.settle()
        #expect(m.state.changedElsewhere)
        #expect(m.state.read?.ways?.run?.programs[0].sha256 == nil, "the read the draft was made from")
        #expect(m.state.draft?.run?.programs.first.map { !m.state.pinForgotten($0) } == true)
    }

    /// A save the vault answers after a lock is `saved` all the same: the page does not survive the lock to show it.
    @Test func aSaveAnsweredAfterALockShowsNoSavedPage() async {
        let gate = TestDeferred<Void>()
        repo.saveGate = gate
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        m.save()
        await pump()
        repo.clear()
        await pump()
        #expect(m.state.read == nil && m.state.draft == nil && m.state.prompt == nil)
        gate.complete()
        await m.settle()
        #expect(m.state.notice == nil && m.state.read == nil && m.state.draft == nil)
        #expect(!m.state.saving)
    }

    /// A password typed when the vault locks goes with the prompt.
    @Test func aLockDropsThePromptAndItsPassword() async {
        repo.answers = [.needsPassword]
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        m.setPassword("pw")
        repo.clear()
        await pump()
        #expect(m.state.prompt == nil)
    }

    /// "Nothing changed" is byte for byte: a program written with the same letters in another Unicode form is a change.
    @Test func aProgramInAnotherUnicodeFormIsAChange() async throws {
        repo.current = "{\"agent_id\":\"a1\",\"item_id\":\"i1\",\"version\":1,\"ways\":[\"use\",\"run\"],\"run\":{\"programs\":[{\"program\":\"caf\u{00E9}\",\"env\":[]}],\"each\":true}}"
        let m = await vm()
        #expect(!m.state.canSave)
        m.openProgram(0)
        m.setEditInput("cafe\u{0301}")
        #expect(m.state.editPending && m.state.canSave)
        m.save()
        await m.settle()
        m.save()
        await m.settle()
        #expect(Array(repo.saves.first?.next.run?.programs[0].program.utf8 ?? "".utf8) == Array("cafe\u{0301}".utf8))
    }

    /// An event this page saw before it opened is not read for; a lock's `clear` forgets it.
    @Test func anEventFromBeforeThePageOpenedIsNotTaken() async {
        repo.fireEvent(item(nil))
        let m = await vm()
        _ = await settled(m)
        #expect(!m.state.notIncluded)
        #expect(repo.reads == 1)
    }

    /// The window a save could not lock is told on the page, and closed from it.
    @Test func theWindowNotClosedIsToldAndClosedFromThePage() async {
        repo.windowNotClosed = WindowNotClosed(ttlSeconds: 120)
        let m = await vm()
        #expect(m.state.windowNotClosed == WindowNotClosed(ttlSeconds: 120))
        m.closeWindowNow()
        await m.settle()
        #expect(repo.closed == 1)
        #expect(m.state.windowNotClosed == nil)
    }

    /// The page prints nothing of what it holds.
    @Test func theStateIsNeverPrinted() async {
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        #expect("\(m.state)" == "ItemWaysState")
        #expect("\(WaysPrompt())" == "WaysPrompt")
        #expect(String(reflecting: m.state) == "ItemWaysState")
    }

    /// A hold empties the page under the cover: it reads again when it is shown or the daily check passes, not a spinner for good.
    @Test func aPageTheHoldEmptiedReadsAgain() async {
        let m = await vm()
        repo.clear()
        await pump()
        #expect(m.state.read == nil)
        let reads = repo.reads
        m.returned()
        await m.settle()
        #expect(repo.reads == reads + 1 && m.state.read != nil && m.state.draft != nil)
        repo.clear()
        await pump()
        m.ownerCheckPassed()
        await m.settle()
        #expect(m.state.read != nil)
        m.ownerCheckPassed()
        await m.settle()
        #expect(repo.reads == reads + 2, "a page that holds its settings is not read again by a passed check")
    }

    /// A read the daily check refused reads again once it passes.
    @Test func aReadTheCheckRefusedReadsAgainWhenItPasses() async {
        repo.failRead = VaultFailure(.ownerCheckRequired)
        let m = await vm()
        #expect(m.state.read == nil && m.state.ownerCheck)
        m.ownerCheckShown()
        m.ownerCheckPassed()
        await m.settle()
        #expect(m.state.read != nil)
    }

    /// The alarm stays on the prompt as the password is typed, and nothing is sent while it shows.
    @Test func nothingIsSentWhileTheAlarmShows() async {
        repo.answers = [.needsPassword, .alarmOpen]
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        m.setPassword("pw")
        m.submitPassword()
        await m.settle()
        #expect(m.state.prompt?.alarm == true && repo.saves.count == 2)
        // The keyboard's Return while the alarm shows sends nothing.
        m.submitPassword()
        await m.settle()
        #expect(repo.saves.count == 2)
        // Typing again clears the alarm, as on Android.
        m.setPassword("again")
        #expect(m.state.prompt?.alarm == false)
    }

    /// **Open the alarm** closes the prompt.
    @Test func openingTheAlarmClosesThePrompt() async {
        repo.answers = [.needsPassword]
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        #expect(m.state.prompt != nil)
        m.openAlarm()
        #expect(m.state.prompt == nil)
    }

    /// A save cut off (a lock, the app leaving) frees the prompt: it is not left sending.
    @Test func aCutOffSaveFreesThePrompt() async {
        repo.answers = [.needsPassword]
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        let gate = TestDeferred<Void>()
        repo.saveGate = gate
        m.setPassword("pw")
        m.submitPassword()
        await pump()
        #expect(m.state.prompt?.sending == true)
        gate.fail(CancellationError())
        await m.settle()
        #expect(m.state.prompt?.sending == false && !m.state.saving)
    }

    /// Save applies a typed program text and shows it; a refused one stays with its problem; nothing is sent until Save again.
    @Test func saveShowsAProgramTextBeforeItSendsIt() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","run"],"run":{"programs":[{"program":"gh","env":[]}],"each":true}}"#
        let m = await vm()
        m.openProgram(0)
        m.setEditInput("g\u{0456}t")
        m.save()
        await m.settle()
        #expect(repo.saves.isEmpty && m.state.prompt == nil)
        #expect(m.state.draft?.run?.programs[0].program == "g\u{0456}t", "the look-alike now shows in its box")
        m.setEditInput("bin/x")
        m.save()
        await m.settle()
        #expect(repo.saves.isEmpty && m.state.editProblem == .notPathOrName)
    }

    /// The same version coming back that this page cannot edit (a repeated pair, an unknown member): the page takes it, and no
    /// draft is left to save from the old reading.
    @Test func aReadOnlyReReadAtTheSameVersionReplacesTheDraft() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#
        let m = await vm()
        m.setReveal(false)
        #expect(m.state.canSave)
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"],"x":1}"#
        m.retry()
        await m.settle()
        #expect(m.state.readOnly && m.state.draft == nil && !m.state.canSave && !m.state.changedElsewhere)
        m.save()
        await m.settle()
        #expect(repo.saves.isEmpty)
    }

    /// A read-only page offers only to turn a way off: turning one on does nothing.
    @Test func aReadOnlyPageIgnoresTurningAWayOn() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use"],"x":1}"#
        let m = await vm()
        m.setRun(true)
        m.setProxy(true)
        m.setReveal(true)
        await m.settle()
        #expect(m.state.confirm == nil && !m.state.addingHost && m.state.draft == nil)
        #expect(repo.saves.isEmpty && repo.offs.isEmpty)
    }

    /// The names say "Loading…" until they are read, and "An item you no longer have" only after.
    @Test func aNameNotReadYetIsNotAnItemYouNoLongerHave() async {
        var s = ItemWaysState()
        #expect(s.shownItemName == ItemWaysStrings.waysItemLoading && s.agentName == ItemWaysStrings.waysItemLoading)
        s.namesLoaded = true
        #expect(s.shownItemName == ItemWaysStrings.waysItemGone)
        s.itemName = "g\u{202E}it"
        #expect(s.shownItemName == AccountNames.isolate("g\u{202E}it") && s.shownItemName != "g\u{202E}it")
    }

    /// The vault's own `GitHub token` reaches a sentence isolated, as an agent's name does.
    @Test func theItemNameInASentenceIsIsolated() async {
        let m = await vm()
        #expect(ItemWaysStrings.waysTitle(m.state.agentName, m.state.shownItemName).contains(AccountNames.isolate("GitHub token")))
    }

    /// A save is recorded with the reading it was made from.
    @Test func aSaveRecordsItsReading() async {
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        m.save()
        await m.settle()
        #expect(repo.saves.first?.cur.ways?.version == 1)
    }

    /// A save's late `needsPassword` or refusal, after a re-read took the settings away, opens no prompt that could never send.
    @Test func aLateAnswerOpensNoPromptForSettingsTheReReadTookAway() async {
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use"]}"#
        let m = await vm()
        m.setReveal(true)
        m.confirm()
        let gate = TestDeferred<Void>()
        repo.saveGate = gate
        repo.answers = [.needsPassword]
        m.save()
        await pump()
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use"],"x":1}"#
        m.retry()
        await pump()
        #expect(m.state.readOnly && m.state.draft == nil)
        gate.complete()
        await m.settle()
        #expect(m.state.prompt == nil)
        m.submitPassword()
        await m.settle()
        #expect(m.state.prompt == nil && !m.state.saving && repo.saves.count == 1)
        // The same for a refusal of the password.
        let gate2 = TestDeferred<Void>()
        repo.saveGate = gate2
        repo.answers = [.passwordRefused(VaultFailure(.badPassword))]
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#
        m.load()
        await m.settle()
        m.setReveal(false)
        m.save()
        await pump()
        repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"],"x":1}"#
        m.retry()
        await pump()
        gate2.complete()
        await m.settle()
        #expect(m.state.prompt == nil)
    }

    /// The item stops being included (the re-read finds it no more) while a save waits: its late refusal or prompt opens no
    /// prompt, and a submit sends nothing and leaves nothing "sending".
    @Test func aLateAnswerOpensNoPromptForAnItemNoLongerIncluded() async {
        for answer in [ItemWaysSave.passwordRefused(VaultFailure(.badPassword)), .needsPassword, .credentialLocked] {
            repo.current = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use"]}"#
            let m = await vm()
            m.setReveal(true)
            m.confirm()
            let gate = TestDeferred<Void>()
            repo.saveGate = gate
            repo.answers = [answer]
            let saves = repo.saves.count
            m.save()
            await pump()
            repo.current = nil
            m.retry()
            await pump()
            #expect(m.state.notIncluded && m.state.draft != nil)
            gate.complete()
            await m.settle()
            #expect(m.state.prompt == nil)
            m.submitPassword()
            await m.settle()
            #expect(m.state.prompt?.sending != true && repo.saves.count == saves + 1)
        }
    }

    /// A read-only re-read, and a forced read, take away an open prompt and an open program page.
    @Test func aReadOnlyReReadAndAForcedReadCloseThePromptAndTheProgramPage() async {
        let programs = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","run"],"run":{"programs":[{"program":"gh","env":[]}],"each":true}}"#
        repo.current = programs
        repo.answers = [.needsPassword]
        let m = await vm()
        m.openProgram(0)
        m.setEach(false)
        m.confirm()
        m.save()
        await m.settle()
        #expect(m.state.prompt != nil && m.state.openProgram == 0)
        repo.current = programs.replacingOccurrences(of: #""each":true"#, with: #""each":true,"x":1"#)
        m.retry()
        await m.settle()
        #expect(m.state.readOnly && m.state.prompt == nil && m.state.openProgram == nil)
        // Forced: Show the current ones.
        repo.current = programs
        m.load()
        await m.settle()
        m.openProgram(0)
        m.setEach(false)
        m.confirm()
        repo.answers = [.needsPassword]
        m.save()
        await m.settle()
        #expect(m.state.prompt != nil)
        m.load()
        await m.settle()
        #expect(m.state.prompt == nil && m.state.openProgram == nil && !m.state.dirty)
    }

    /// An agent gone from the loaded list is "an agent", not "Loading…" for good; a blank item name is no name.
    @Test func goneAgentsAndBlankItemNamesHaveTheirFallbacks() async {
        var s = ItemWaysState()
        s.namesLoaded = true
        s.agentsLoaded = true
        #expect(s.agentName == DeviceStrings.devicesAnAgent)
        s.itemName = " \u{200B} "
        #expect(s.shownItemName == ItemWaysStrings.waysItemGone)
        s.namesLoaded = false
        #expect(s.shownItemName == ItemWaysStrings.waysItemLoading)
        let m = await vm()
        devices.devices = []
        #expect(m.state.agentName == DeviceStrings.devicesAnAgent)
    }
}
// swiftlint:enable line_length
