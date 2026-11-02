#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import VettIDData
import VettIDUI
@testable import VettIDVotes
@testable import VettIDVotesUI

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The Votes screens (ANDROID-PLAN 0.1.102 to 0.1.108 §4 "Votes"; IOS-PLAN §4.16): every state of the list and of a vote
/// rendered, the unlock window notice on both screens, the dropped notice acknowledged, the vote kept out of captures, the
/// secrets dropped when the screen leaves, and the proof document. What the screens say is checked, as text, in
/// `VoteFactsTests` and `VoteStringsTests` (the hosted tree gives no text without an assistive technology). Mirrors
/// vettid-android `VoteScreenTest`.
@MainActor
@Suite(.serialized) struct VotesScreensTests {
    private var chrome: ShellChrome { ShellChrome(accountName: "Ada Lovelace", onMenu: {}, onAvatar: {}) }

    private func listState(_ change: (inout VotesState) -> Void) -> VotesState {
        var s = VotesState()
        s.load = .loaded
        s.services = ["c1": "Example Org"]
        change(&s)
        return s
    }

    @Test func everyListStateRenders() {
        var loading = VotesState()
        loading.load = .loading
        let failed = listState { $0.error = .network }
        let empty = listState { _ in }
        let full = listState {
            $0.votes = [Samples.open(), Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .verified)), Samples.open(state: .checking)]
            $0.reconnect = [ReconnectEntry(connectionID: "c9", serviceID: "s", name: "Other")]
            $0.dropped = [DroppedNotice(connectionID: "c1", count: 2)]
            $0.problems = [ProblemsNotice(connectionID: "c1", count: 3)]
            $0.windowNotClosed = WindowNotClosed(ttlSeconds: 120)
            $0.error = .network
        }
        for s in [loading, failed, empty, full] {
            #expect(height(VotesScreen(state: s, chrome: chrome, actions: VotesActions())) > 0, "\(s)")
            #expect(height(ConnectionVotesScreen(state: s, onBack: {}, actions: VotesActions())) > 0, "\(s)")
        }
    }

    @Test func aShownDroppedNoticeIsAcknowledgedOnceTheListWasRead() {
        var acknowledged: [[String]] = []
        var actions = VotesActions()
        actions.onNoticesShown = { acknowledged.append($0) }
        var s = listState { $0.dropped = [DroppedNotice(connectionID: "c1", count: 2)]; $0.votes = [Samples.open()] }
        _ = host(VotesScreen(state: s, chrome: chrome, actions: actions))
        #expect(acknowledged == [["c1"]])
        // Not before the list was read.
        acknowledged = []
        s.load = .loading
        _ = host(VotesScreen(state: s, chrome: chrome, actions: actions))
        #expect(acknowledged.isEmpty)
    }

    /// Owner behaviour 1: the notice renders on the list and on the vote (its words are checked in `VoteFactsTests`).
    @Test func theWindowNoticeRendersOnTheListAndOnTheVote() {
        var notice = listState { $0.votes = [Samples.open()] }
        notice.windowNotClosed = WindowNotClosed(ttlSeconds: 600)
        #expect(height(VotesScreen(state: notice, chrome: chrome, actions: VotesActions())) > 0)
        var closeAsked = 0
        var actions = VotesActions()
        actions.onCloseWindow = { closeAsked += 1 }
        _ = host(VotesScreen(state: notice, chrome: chrome, actions: actions))
        var vote = Samples.screen(Samples.open())
        vote.windowNotClosed = WindowNotClosed(ttlSeconds: 90)
        #expect(facts(vote).windowNotClosed != nil && facts(Samples.screen(Samples.open())).windowNotClosed == nil)
        #expect(height(VoteContent(state: vote, facts: facts(vote), actions: VoteActions())) > 0)
        #expect(closeAsked == 0)
    }

    @Test func everyVoteStateRenders() {
        let confirm = Samples.open(confirmPending: true)
        let states: [VoteScreenState] = [
            VoteScreenState(key: Samples.key),
            Samples.screen(nil) { $0.loaded = true },
            Samples.screen(nil) { $0.loadError = VoteProblem(kind: .network) },
            Samples.screen(Samples.open()),
            Samples.screen(Samples.open()) { $0.selected = "yes" },
            Samples.screen(Samples.open(ballot: VoteBallot(state: .waiting), canCast: false)),
            Samples.screen(confirm, detail: Samples.detail(confirm, serviceBallot: "no")),
            Samples.screen(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .verified), conflict: true)),
            Samples.screen(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .verified)), detail: resultsDetail()),
            Samples.screen(Samples.closed(VoteBallot(state: .conflict), check: VoteCheck(state: .failed))) { $0.proofExported = true; $0.proofSaved = true },
            Samples.screen(Samples.open(canCast: false, state: .rejected, reason: "anchor")),
            Samples.screen(Samples.open()) { $0.castProblem = VoteProblem(kind: .noResponse); $0.alreadyVoted = true; $0.checkProblem = VoteProblem(kind: .network) },
            Samples.screen(Samples.open()) { $0.windowNotClosed = WindowNotClosed(ttlSeconds: nil); $0.windowCloseProblem = VoteProblem(kind: .network) },
            Samples.screen(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .pending))) { $0.checkOutcome = .notPublished },
        ]
        for s in states { #expect(height(VoteScreen(state: s, actions: VoteActions())) > 0, "\(s)") }
    }

    @Test func everySheetRenders() {
        let s = Samples.open()
        let confirm = Samples.open(confirmPending: true)
        let sheets: [VoteScreenState] = [
            Samples.screen(s) { $0.selected = "yes"; $0.cast = .confirm },
            Samples.screen(s) { $0.selected = "yes"; $0.cast = .sending },
            Samples.screen(s) { $0.selected = "yes"; $0.cast = .password },
            Samples.screen(s) { $0.selected = "yes"; $0.cast = .password; $0.passwordError = VoteProblem(kind: .badPassword) },
            Samples.screen(s) { $0.selected = "yes"; $0.cast = .sending; $0.password = "x" },
        ]
        for st in sheets { #expect(height(CastSheet(state: st, actions: VoteActions())) > 0, "\(st)") }
        let restore = Samples.screen(confirm, detail: Samples.detail(confirm, serviceBallot: "no"))
        #expect(height(RestoreSheet(state: restore, actions: VoteActions())) > 0)
        var busy = restore
        busy.restoreBusy = true
        busy.restoreProblem = VoteProblem(kind: .network)
        #expect(height(RestoreSheet(state: busy, actions: VoteActions())) > 0)
        let release = Samples.screen(Samples.closed(VoteBallot(state: .conflict))) { $0.proofExported = true; $0.releaseDialog = true }
        #expect(height(ReleaseSheet(state: release, actions: VoteActions())) > 0)
        var refused = release
        refused.releaseProblem = VoteProblem(kind: .other, code: "evidence_not_exported")
        #expect(height(ReleaseSheet(state: refused, actions: VoteActions())) > height(ReleaseSheet(state: release, actions: VoteActions())))
    }

    /// The release sheet's PIN is on the in-app keypad (IOS-PLAN §6.5): no text field, so no keyboard sees it.
    @Test func theReleasePinHasNoTextField() {
        let release = Samples.screen(Samples.closed(VoteBallot(state: .conflict))) { $0.proofExported = true; $0.releaseDialog = true }
        let window = host(ReleaseSheet(state: release, actions: VoteActions()))
        #expect(!views(in: window).contains { $0 is UITextField })
    }

    /// The credential password is on the secret field of IOS-PLAN §6.5: a masked field with no AutoFill.
    @Test func thePasswordIsOnTheSecretField() {
        let st = Samples.screen(Samples.open()) { $0.cast = .password; $0.password = "x" }
        let window = host(CastSheet(state: st, actions: VoteActions()))
        let fields = views(in: window).compactMap { $0 as? UITextField }
        #expect(!fields.isEmpty && fields.allSatisfy { $0.isSecureTextEntry && $0.autocorrectionType == .no })
        #expect(fields.allSatisfy { $0.textContentType?.rawValue == "" })
    }

    // MARK: The proof's temporary file

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("votes-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func entries(_ root: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] }

    @Test func theTemporaryFileIsTheEvidenceUnchangedUnderItsNameAndGoesWhenRemoved() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = #"{"evidence":{"choice_id":"yes","sig":"AbC=="}}"#
        let t = try ProofTempFile.write(ProofFile(bytes: Data(text.utf8), name: "vettid-vote-p1.json"), in: root)
        #expect(try Data(contentsOf: t.url) == Data(text.utf8) && t.url.lastPathComponent == "vettid-vote-p1.json")
        #expect(entries(root).count == 1 && entries(root)[0].hasPrefix(ProofTempFile.prefix))
        // Complete file protection where the system reports it.
        let attributes = try FileManager.default.attributesOfItem(atPath: t.url.path)
        if let protection = attributes[.protectionKey] as? FileProtectionType { #expect(protection == .complete) }
        t.remove()
        #expect(entries(root).isEmpty)
        #expect(ProofTempFile.removeLeftovers(in: root) == 0)
    }

    @Test func leftoversOfAKilledAppAreRemoved() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ProofTempFile.write(ProofFile(bytes: Data("x".utf8), name: "a.json"), in: root)
        _ = try ProofTempFile.write(ProofFile(bytes: Data("y".utf8), name: "b.json"), in: root)
        try Data().write(to: root.appendingPathComponent("other.txt"))
        #expect(ProofTempFile.removeLeftovers(in: root) == 2 && entries(root) == ["other.txt"])
    }

    /// The file is removed on every path: a pick, a cancel, the screen leaving, the file taken away, and the next file.
    @Test func theTemporaryFileGoesOnEveryPath() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = ProofFile(bytes: Data("evidence".utf8), name: "p.json")
        let host = UIViewController()
        func run(_ end: (ProofExportCoordinator, UIDocumentPickerViewController) -> Void) -> [Bool] {
            let c = ProofExportCoordinator()
            c.root = root
            var answers: [Bool] = []
            c.onAnswered = { answers.append($0) }
            c.update(file, host: host)
            #expect(entries(root).count == 1, "the file exists while the picker is up")
            end(c, UIDocumentPickerViewController(forOpeningContentTypes: [.json]))
            #expect(entries(root).isEmpty, "removed")
            return answers
        }
        #expect(run { c, p in c.documentPicker(p, didPickDocumentsAt: [c.temp!.url]) } == [true])
        #expect(run { c, p in c.documentPickerWasCancelled(p) } == [false])
        #expect(run { c, _ in c.leave() }.isEmpty)
        #expect(run { c, _ in c.update(nil, host: host) }.isEmpty)
        // The same file again while the picker is up makes no second file; a failure to write is told.
        let c = ProofExportCoordinator()
        c.root = root
        c.update(file, host: host)
        c.update(file, host: host)
        #expect(entries(root).count == 1)
        c.leave()
        var failed = 0
        c.onFailed = { failed += 1 }
        c.root = root.appendingPathComponent("missing/deeper")
        c.update(file, host: host)
        #expect(failed == 0, "told after the update that asked, not during it")
        try await Task.sleep(for: .seconds(0.1))
        #expect(failed == 1 && c.temp == nil)
    }

    /// A picker that cannot be presented (no window) leaves no file and is told as a failure, once.
    @Test func aPickerThatCannotBePresentedRemovesTheFileAndIsTold() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = ProofExportCoordinator()
        c.root = root
        var failed = 0
        var answered: [Bool] = []
        c.onFailed = { failed += 1 }
        c.onAnswered = { answered.append($0) }
        c.update(ProofFile(bytes: Data("evidence".utf8), name: "p.json"), host: UIViewController())
        #expect(entries(root).count == 1 && failed == 0)
        try await Task.sleep(for: .seconds(0.1))
        #expect(entries(root).isEmpty && c.temp == nil && failed == 1 && answered.isEmpty)
    }

    /// A close between the update and the hop opens no picker for a deleted file and tells nothing.
    @Test func aCloseBeforeThePresentationOpensNothing() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = ProofExportCoordinator()
        c.root = root
        var failed = 0
        var presented = 0
        c.onFailed = { failed += 1 }
        c.presentPicker = { _, _ in presented += 1 }
        let window = windowed(UIViewController())
        let controller = try #require(window.rootViewController)
        c.update(ProofFile(bytes: Data("evidence".utf8), name: "p.json"), host: controller)
        c.leave()
        try await Task.sleep(for: .seconds(0.2))
        #expect(entries(root).isEmpty && failed == 0 && presented == 0)
    }

    /// With the host on screen and nothing over it, the picker is presented from the host, once; a presentation UIKit does
    /// not take (it only logs one made while another is under way) removes the file and is told, once.
    @Test func aPresentationUIKitDidNotTakeRemovesTheFileAndIsTold() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = ProofExportCoordinator()
        c.root = root
        var failed = 0
        var answered: [Bool] = []
        var presenters: [UIViewController] = []
        c.onFailed = { failed += 1 }
        c.onAnswered = { answered.append($0) }
        c.presentPicker = { presenter, picker in
            presenters.append(presenter)
            #expect(picker is UIDocumentPickerViewController)
        }
        let window = windowed(UIViewController())
        let controller = try #require(window.rootViewController)
        c.update(ProofFile(bytes: Data("evidence".utf8), name: "p.json"), host: controller)
        #expect(entries(root).count == 1)
        try await Task.sleep(for: .seconds(0.2))
        #expect(presenters.count == 1 && presenters.first === controller)
        #expect(entries(root).isEmpty && c.temp == nil && failed == 1 && answered.isEmpty)
    }

    /// While another presentation is under way the picker waits and is presented once it is free; busy past every try, the
    /// file goes and the failure is told once, with nothing presented.
    @Test func aBusyHostIsWaitedForThenGivenUpOn() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = windowed(UIViewController())
        let controller = try #require(window.rootViewController)
        struct Outcome { var asked = 0, presented = 0, failed = 0, files = 0 }
        func run(busyFor: Int) async throws -> Outcome {
            let c = ProofExportCoordinator()
            c.root = root
            c.retryDelay = 0.01
            var o = Outcome()
            c.busy = { _ in o.asked += 1; return o.asked <= busyFor }
            c.presentPicker = { _, _ in o.presented += 1 }
            c.onFailed = { o.failed += 1 }
            c.update(ProofFile(bytes: Data("evidence".utf8), name: "p.json"), host: controller)
            try await Task.sleep(for: .seconds(0.4))
            o.files = entries(root).count
            c.leave()
            return o
        }
        let tries = ProofExportCoordinator.presentTries
        // Free on the last try: presented once (the test's presentation takes nothing, so the backstop then tells it).
        let late = try await run(busyFor: tries - 1)
        #expect(late.asked == tries && late.presented == 1)
        // Busy on every try: never presented, told once, the file gone.
        let never = try await run(busyFor: .max)
        #expect(never.asked == tries && never.presented == 0 && never.failed == 1 && never.files == 0)
    }

    /// A close while the picker waits for a busy host ends the tries: nothing is presented or told.
    @Test func aCloseWhileWaitingEndsTheTries() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = windowed(UIViewController())
        let controller = try #require(window.rootViewController)
        let c = ProofExportCoordinator()
        c.root = root
        c.retryDelay = 0.05
        var asked = 0, presented = 0, failed = 0
        c.busy = { _ in asked += 1; return true }
        c.presentPicker = { _, _ in presented += 1 }
        c.onFailed = { failed += 1 }
        c.update(ProofFile(bytes: Data("evidence".utf8), name: "p.json"), host: controller)
        try await Task.sleep(for: .seconds(0.02))
        c.leave()
        try await Task.sleep(for: .seconds(0.4))
        #expect(asked == 1 && presented == 0 && failed == 0 && entries(root).isEmpty)
    }

    /// A host with nothing over it and no transition is free to present.
    @Test func aHostWithNothingOverItIsNotBusy() {
        let window = windowed(UIViewController())
        let controller = window.rootViewController!
        #expect(!ProofExportCoordinator.isBusy(controller))
    }

    /// The presentation starts from the controller itself when nothing is presented over it (a modal over a test window needs a
    /// scene, which a unit test host does not give, so the chain is not built here).
    @Test func thePresentationStartsFromTheHostWhenNothingIsPresented() {
        let host = UIViewController()
        #expect(ProofExportCoordinator.topmost(host) === host)
    }

    /// The vote screen holds no exporter of its own: nothing is written until the evidence is ready.
    @Test func nothingIsWrittenWhileTheEvidenceIsNotReady() throws {
        let before = ProofTempFile.removeLeftovers()
        _ = host(VoteScreen(state: Samples.screen(Samples.closed(VoteBallot(state: .conflict))), proof: nil, actions: VoteActions()))
        #expect(ProofTempFile.removeLeftovers() == 0 && before >= 0)
    }

    // MARK: Capture and secrets

    /// IOS-PLAN §4.16 Screen privacy (ANDROID-PLAN decision A, 2026-10-31): the vote screen and its sheets are on the secure layer, always,
    /// whatever "Allow screenshots" says (as Android's `FLAG_SECURE` and the recovery screen).
    @Test func theVoteIsKeptOutOfCapturesWhateverTheAllowanceSays() {
        guard SecureLayer.isAvailable else { return }
        let screen = VoteScreen(state: Samples.screen(Samples.open()), actions: VoteActions())
        let protected = host(screen.environment(ScreenshotAllowance(onByDefault: false)))
        let allowed = host(screen.environment(ScreenshotAllowance(onByDefault: true)))
        #expect(views(in: protected).contains(where: onSecureLayer) && views(in: allowed).contains(where: onSecureLayer))
        #expect(views(in: protected).filter(onSecureLayer).count == views(in: allowed).filter(onSecureLayer).count)
        for sheet in [
            host(CastSheet(state: Samples.screen(Samples.open()) { $0.cast = .confirm }, actions: VoteActions()).environment(ScreenshotAllowance(onByDefault: true))),
            host(CastSheet(state: Samples.screen(Samples.open()) { $0.cast = .password }, actions: VoteActions()).environment(ScreenshotAllowance(onByDefault: true))),
            host(ReleaseSheet(state: Samples.screen(Samples.closed(VoteBallot(state: .conflict))), actions: VoteActions()).environment(ScreenshotAllowance(onByDefault: true))),
            host(RestoreSheet(state: Samples.screen(Samples.open(confirmPending: true)), actions: VoteActions()).environment(ScreenshotAllowance(onByDefault: true))),
        ] { #expect(views(in: sheet).contains(where: onSecureLayer)) }
    }

    /// The sheet keeps the password step while a request sent with the password is under way, though the password was dropped.
    @Test func thePasswordStepStaysWhileTheRequestIsUnderWay() {
        let password = Samples.screen(Samples.open()) { $0.cast = .sending; $0.castWithPassword = true; $0.password = "" }
        let confirm = Samples.screen(Samples.open()) { $0.cast = .sending; $0.castWithPassword = false }
        let passwordFields = views(in: host(CastSheet(state: password, actions: VoteActions()))).compactMap { $0 as? UITextField }
        let confirmFields = views(in: host(CastSheet(state: confirm, actions: VoteActions()))).compactMap { $0 as? UITextField }
        #expect(!passwordFields.isEmpty && confirmFields.isEmpty)
    }

    @Test func leavingTheScreenAsksTheModelToForgetThePasswordAndUnsavedEvidence() {
        var left = 0
        var actions = VoteActions()
        actions.onLeave = { left += 1 }
        var window: UIWindow? = host(VoteScreen(state: Samples.screen(Samples.open()), actions: actions))
        window?.rootViewController = nil
        window = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(left >= 1)
    }

    // MARK: Helpers

    private func resultsDetail() -> VoteDetail {
        var d = Samples.detail(Samples.closed(VoteBallot(state: .recorded)), choiceID: "yes")
        d.tally = ["yes": 3, "no": 1]
        d.counts = VoteCounts(eligible: 9, ballots: 4, unhandled: 2)
        return d
    }

    private func facts(_ s: VoteScreenState) -> VoteFacts { VoteFacts.of(s, summary: s.summary ?? Samples.open(), now: Samples.t0) }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return window
    }

    /// A window with [controller] as its root, on screen.
    private func windowed(_ controller: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }

    private func onSecureLayer(_ v: UIView) -> Bool { String(describing: type(of: v)).contains("Canvas") }
}
// swiftlint:enable line_length
#endif
