#if os(iOS)
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding
@testable import VettIDOnboardingUI
@testable import VettIDUI

// swiftlint:disable line_length

/// The recovery's screens (VAULT-MESSAGING §11.11, §11.11.10, §11.14.6): the texts (vettid-android's, word for word), every
/// step and answer rendered, the PIN on the keypad and the code in a field without suggestions, a hold or the background that
/// empties them, and the routes that own their models. Mirrors vettid-android's `RecoverTypeScreenTest`, `RecoveryOpenTextTest`
/// and `RecoverLeaveScreenTest`.
@MainActor
@Suite struct RecoveryScreensTests {
    @Test func theTextsAreAndroids() {
        #expect(RecoveryScreenStrings.recoverTitle == "Recover your vault" && RecoveryScreenStrings.recoverScan == "Scan the code")
        #expect(RecoveryScreenStrings.recoverBody("within 24 hours") == "Your account site shows a recovery QR code within 24 hours after you start a recovery there. Open it (Vault, then Recovery, then Show the code) and scan it with this phone, or type the code shown under it.")
        #expect(RecoveryScreenStrings.recoverType == "Type the code instead" && RecoveryScreenStrings.recoverScanInstead == "Scan instead")
        #expect(RecoveryScreenStrings.recoverTypeGroups(5, 12) == "5 of 12 groups")
        #expect(RecoveryScreenStrings.recoverTypeBody == "On the account site, under the QR code, there are 12 groups of four characters. Type them all, in order.")
        #expect(RecoveryScreenStrings.recoverStartOverBody.contains("Your vault is not changed.") && RecoveryScreenStrings.recoverStartOverBody.contains("goes back to the start. There you can recover again, use a setup code or move VettID from your old phone.\n\nThe recovery itself"))
        #expect(RecoveryScreenStrings.recoverNoBackupStartOver == "Delete my vault and start over" && RecoveryScreenStrings.recoverNoBackupNewVault == "I have a new setup code")
        #expect(RecoveryScreenStrings.onboardingOpenTitle == "Your PIN and your password" && RecoveryScreenStrings.onboardingOpenTen == "Enter both. You have 10 attempts in total for this vault, not 10 a day.")
        #expect(RecoveryScreenStrings.onboardingOpenCheck("975310", "pw") == "This is what will be sent. PIN: 975310. Password: pw. Look at both. A wrong entry uses one of your attempts.")
        #expect(RecoveryScreenStrings.onboardingOpenLostTitle == "Finish with your PIN" && RecoveryScreenStrings.onboardingOpenFinishGo == "Finish")
        #expect(RecoveryScreenStrings.onboardingOpenFinishEraseBody.hasPrefix("This erases VettID's data on this phone only") && RecoveryScreenStrings.onboardingOpenFinishEraseBody.contains("\n\nYour vault was recovered onto this phone"))
        #expect(RecoveryScreenStrings.onboardingOpenNewRecovery == "Start a new recovery" && RecoveryScreenStrings.onboardingOpenBack == "Back to the recovery")
        #expect(RecoveryStrings.recoverEndedTitle == "This recovery has ended" && RecoveryStrings.recoverUndecidedNewCode == "Use a new recovery code")
    }

    /// The groups of four, four to a row, as the code is drawn while typing.
    @Test func theTypedCodeIsDrawnInGroups() {
        #expect(TypedCodeFormat.grouped("") == "" && TypedCodeFormat.grouped("7ZK") == "7ZK")
        #expect(TypedCodeFormat.grouped("7ZK3M9QX") == "7ZK3 M9QX")
        #expect(TypedCodeFormat.grouped("7ZK3M9QX2HTDCDEFGHJKMNPQ") == "7ZK3 M9QX 2HTD CDEF\nGHJK MNPQ")
        #expect(TypedCodeFormat.grouped("7ZK3M9QX2HTDCDEFGHJKMNPQRSTVWXYZ0123456789ABV3A1").split(separator: "\n").count == 3)
        #expect(RecoverState.codeGroup == 4 && RecoverState.codeGroups == 12)
    }

    // MARK: - Every step renders

    var recoverStates: [(String, RecoverState)] {
        func with(_ step: RecoverStep, _ edit: (inout RecoverState) -> Void = { _ in }) -> RecoverState {
            var s = RecoverState(step: step, startOverURL: "https://account.vettid.org/account/vault/deletion/", accountHost: "account.vettid.org")
            edit(&s)
            return s
        }
        var states: [(String, RecoverState)] = [
            ("loading", with(.loading)), ("intro", with(.intro)), ("stage failed", with(.stageFailed) { $0.error = .network }),
            ("scan", with(.scan)), ("type", with(.type)), ("type, typed", with(.type) { $0.typed = "7ZK3M9QX2HTD" }),
            ("registering", with(.registering) { $0.busy = true }), ("open", with(.open)), ("no backup", with(.noBackup)),
            ("confirm start over", with(.open) { $0.confirmStartOver = true }),
            ("rate limited", with(.scan) { $0.error = .rateLimited; $0.retrySeconds = 42 }),
            ("no answer", with(.intro) { $0.error = .noResponse }),
            ("typed, complete", with(.type) { $0.typed = String(repeating: "7ZK3", count: 12) }),
            ("could not tell", with(.couldNotTell) { $0.couldNotTell = .newCode }),
        ]
        for r in CodeRefusal.allCases {
            states.append(("scan, \(r)", with(.scan) { $0.refusal = r; $0.otherApi = "https://account.example.org"; $0.wrongCodes = 3 }))
        }
        for p in TypedProblem.allCases {
            states.append(("type, \(p)", with(.type) { $0.typedProblem = p; $0.typedGroup = 3 }))
        }
        for code in [
            VaultManager.codeRecoveryOpenSent, MoveCodes.recoveryOpened, VaultManager.codeRecoveryOpenPending,
            VaultManager.codeRecoveryOpenUnknown, VaultManager.codeRecoveryRegistered,
        ] {
            for step in [RecoverStep.intro, .scan, .type, .open] {
                states.append(("\(step), \(code)", with(step) { $0.errorCode = code }))
            }
        }
        return states
    }

    @Test func everyRecoverStepRenders() {
        for (name, s) in recoverStates {
            #expect(height(RecoverContent(state: s, camera: AnyView(Color.gray), openPane: AnyView(Text("open")))) > 0, "\(name)")
        }
        #expect(Set(recoverStates.map(\.1.step)) == Set(RecoverStep.allCases))
    }

    var openStates: [(String, RecoveryOpenState)] {
        func with(_ step: OpenStep, used: Int? = nil, _ edit: (inout RecoveryOpenState) -> Void = { _ in }) -> RecoveryOpenState {
            var s = RecoveryOpenState(step: step, used: used)
            edit(&s)
            return s
        }
        let retry = Date().addingTimeInterval(7_200)
        var states: [(String, RecoveryOpenState)] = [
            ("enter", with(.enter)), ("enter, entries", with(.enter) { $0.pin = "975310"; $0.password = "pw" }),
            ("check", with(.check) { $0.pin = "975310"; $0.password = "pw" }),
            ("check, second", with(.check, used: 1) { $0.pin = "975310"; $0.password = "pw" }),
            ("check, few left", with(.check, used: 8) { $0.pin = "975310"; $0.password = "pw" }),
            ("sending", with(.sending)), ("finish", with(.finish)), ("finish, lost ok", with(.finish) { $0.lostOk = true }),
            ("finish, bad pin", with(.finish) { $0.outcome = RecoveryOpenOutcome("bad_pin", opened: true) }),
            ("finish, failure", with(.finish) { $0.failure = .network }),
            ("finish, can erase", with(.finish) { $0.outcome = RecoveryOpenOutcome("device_secret", opened: true) }),
            ("finish, erase confirm", with(.finish) { $0.outcome = RecoveryOpenOutcome("device_secret", opened: true); $0.confirmErase = true }),
            ("done", with(.done, used: 3) { $0.outcome = RecoveryOpenOutcome("ok", used: 3) }),
            ("done, plain", with(.done)), ("done, lock pending", with(.done) { $0.failure = .other; $0.failureCode = MoveCodes.lockPending }),
            ("done, not opened", with(.done) { $0.failure = .other; $0.failureCode = MoveCodes.notOpened }),
            ("no answer", with(.answered) { $0.failure = .noResponse }), ("unreadable", with(.answered) { $0.failure = .other; $0.failureCode = RecoveryOpenState.codeUnreadable }),
            ("network", with(.answered) { $0.failure = .network }),
        ]
        for code in ["wrong", "wrong_again", "attempt_lost", "quiet", "wait", "busy", "retry", "stored_mismatch", "vault_missing", "exhausted", "closed", "not_armed", "counter_unavailable", "no_recovery", "expired", "attestation", "manifest", "wrong_release", "bad_request", "something_else"] {
            states.append(("answer \(code)", with(.answered, used: 2) { $0.outcome = RecoveryOpenOutcome(code, used: 2) }))
            states.append(("answer \(code), waiting", with(.answered, used: 2) { $0.outcome = RecoveryOpenOutcome(code, used: 2, retryAt: retry, attemptUsed: false) }))
        }
        states.append(("answer, could not recover", with(.answered) { $0.outcome = RecoveryOpenOutcome("exhausted", contactCouldNotRecover: true); $0.couldNotTell = .unlockOrNewCode }))
        states.append(("finish, took phone", with(.finish) { $0.outcome = RecoveryOpenOutcome("bad_pin", opened: true); $0.couldNotTell = .contact }))
        states.append(("finish, unlock or new code", with(.finish) { $0.lostOk = true; $0.couldNotTell = .unlockOrNewCode }))
        states.append(("no recovery, unanswered", with(.answered) { $0.outcome = RecoveryOpenOutcome("no_recovery", afterUnanswered: true) }))
        states.append(("right but incomplete", with(.answered) { $0.outcome = RecoveryOpenOutcome("wait", retryAt: retry, afterUnanswered: true); $0.rightButIncomplete = true }))
        return states
    }

    @Test func everyOpenStepRenders() {
        for (name, s) in openStates {
            #expect(height(RecoveryOpenContent(state: s, onStartOver: {})) > 0, "\(name)")
            #expect(height(RecoveryOpenContent(state: s)) > 0, "\(name), no start over")
        }
        #expect(Set(openStates.map(\.1.step)) == Set(OpenStep.allCases))
        for g in [RecoverGuidance.finishWithPin, .alreadyRecovered, .tryOpenAgain, .retry, .startOverFirst] {
            #expect(height(RecoveryOpenContent(state: RecoveryOpenState(), problem: .guidance(g), onStartOver: {})) > 0, "\(g)")
        }
        #expect(height(RecoveryOpenContent(state: RecoveryOpenState(), problem: .failure(.network), onStartOver: {})) > 0)
    }

    /// The answers of the table say their own words, and the right actions stand beside them.
    @Test func theAnswersAreTheTable() {
        let o = RecoveryOpenOutcome("wrong", used: 3)
        let text = RecoveryTexts.openAnswer(openAnswerText(o, rightButIncomplete: false), retryAt: "")
        #expect(text.hasPrefix("PIN or password is wrong. The vault does not tell us which."))
        #expect(openCanTryAgain("wrong") && !openCanTryAgain("exhausted") && openNeedsNewRecovery("expired") && !openNeedsNewRecovery("wrong"))
    }

    /// (IOS-PLAN §4.9) The rule's texts come before the table's, and "Use a new recovery code" stands beside the PIN only while
    /// the rule lets a new recovery use this phone.
    @Test func theRuleSaysItsOwnWordsAndOffersANewCodeOnlyWhenAllowed() {
        var ruled = RecoveryOpenState(step: .finish)
        ruled.outcome = RecoveryOpenOutcome("exhausted", opened: true, contactCouldNotRecover: true)
        #expect(finishRuleText(ruled, ruled.outcome!) == RecoveryStrings.recoverCouldNotRecover)
        ruled.couldNotTell = .contact
        #expect(finishRuleText(ruled, ruled.outcome!) == RecoveryStrings.onboardingOpenTookPhone)
        // A wrong PIN, a wait or a failure on the way says its own words, also a day after the refusals began.
        for code in ["bad_pin", "backoff", "network", "rate_limited"] {
            #expect(finishRuleText(ruled, RecoveryOpenOutcome(code, opened: true)) == nil, "\(code)")
        }
        #expect(finishRuleText(RecoveryOpenState(), RecoveryOpenOutcome("exhausted")) == nil)

        for rule in [CouldNotTellStage.none, .waiting(until: Date()), .finishWithPin, .newCode, .contact, .unlockOrNewCode] {
            var s = RecoveryOpenState(step: .finish)
            s.couldNotTell = rule
            let offered = rule == .newCode || rule == .unlockOrNewCode
            #expect((newCodeAction(s, {}) != nil) == offered, "\(rule)")
            #expect(newCodeAction(s, nil) == nil, "\(rule), no action")
        }
        // On the finish step only beside the lost-ok PIN, never on the finish of a confirmed `ok`.
        var finish = RecoveryOpenState(step: .finish)
        finish.couldNotTell = .unlockOrNewCode
        #expect(finishNewCodeAction(finish, {}) == nil)
        finish.lostOk = true
        #expect(finishNewCodeAction(finish, {}) != nil)
    }

    // MARK: - The PIN and the code

    /// The PIN is the keypad's: no text field takes it. The open step has the password's secret field and nothing else; the
    /// finish by PIN has no text field at all.
    @Test func noKeyboardForThePin() {
        for (name, s) in openStates {
            let window = host(RecoveryOpenContent(state: s, onStartOver: {}))
            let fields = textFields(in: window)
            #expect(views(in: window).compactMap { $0 as? UITextView }.isEmpty, "\(name)")
            if s.step == .enter {
                #expect(fields.count == 1 && fields[0].isSecureTextEntry && fields[0].textContentType?.rawValue == "", "\(name)")
                #expect(fields[0].keyboardType == .asciiCapable && fields[0].autocorrectionType == .no, "\(name)")
            } else {
                #expect(fields.isEmpty, "\(name)")
            }
            window.isHidden = true
        }
    }

    /// The typed code: one editor with no AutoFill, autocorrection, spell checking or predictions, that never copies.
    @Test func theCodeFieldSuggestsNothingAndNeverCopies() throws {
        var state = RecoverState(step: .type, accountHost: "account.vettid.org")
        state.typed = "7ZK3M9QX"
        let window = host(RecoverContent(state: state))
        let editors = views(in: window).compactMap { $0 as? UITextView }
        let editor = try #require(editors.first)
        #expect(editors.count == 1 && textFields(in: window).isEmpty)
        #expect(editor.textContentType?.rawValue == "")
        #expect(editor.autocorrectionType == .no && editor.spellCheckingType == .no && editor.inlinePredictionType == .no)
        #expect(editor.smartQuotesType == .no && editor.smartDashesType == .no && editor.smartInsertDeleteType == .no)
        #expect(editor is PasteOnlyTextView && !editor.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        #expect(editor.text == "7ZK3 M9QX", "the code is drawn in groups of four")
        window.isHidden = true
        // The other steps have no editor.
        for (name, s) in recoverStates where s.step != .type {
            let other = host(RecoverContent(state: s, camera: AnyView(Color.gray), openPane: AnyView(EmptyView())))
            #expect(views(in: other).compactMap { $0 as? UITextView }.isEmpty && textFields(in: other).isEmpty, "\(name)")
            other.isHidden = true
        }
    }

    /// The phone locks (or the app leaves the foreground): the digits typed go, and the model is told to drop its entries.
    @Test func aHoldEmptiesThePin() async {
        let log = ActionLog()
        let pin = PinBuffer()
        var actions = RecoveryOpenActions()
        actions.forgetSecrets = { log.items.append("forget") }
        let window = host(RecoveryOpenContent(state: RecoveryOpenState(), actions: actions, problem: nil, onStartOver: nil, pin: pin))
        for d in [9, 7, 5, 3, 1, 0] { pin.append(d) }
        #expect(pin.count == 6)
        NotificationCenter.default.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        let emptied = await eventually { pin.count == 0 && log.items == ["forget"] }
        #expect(emptied, "the digits went with the lock, and the model was told")
        window.isHidden = true
    }

    /// The model's entries fill the keypad again when the fields come back ("Change", "Try again"): they are kept.
    @Test func theEntriesComeBackToTheKeypad() async {
        var state = RecoveryOpenState()
        state.pin = "975310"
        state.password = "pw"
        let pin = PinBuffer()
        let window = host(RecoveryOpenContent(state: state, actions: RecoveryOpenActions(), problem: nil, onStartOver: nil, pin: pin))
        let filled = await eventually { pin.count == 6 }
        #expect(filled)
        window.isHidden = true
    }

    // MARK: - The notices on every open step

    /// A refused or failed start over is told on the answer, the check and the finish as well as on the fields.
    @Test func theStartOverNoticeShowsOnEveryOpenStep() {
        var answered = RecoveryOpenState(step: .answered)
        answered.outcome = RecoveryOpenOutcome("wrong", used: 1)
        var unanswered = RecoveryOpenState(step: .answered)
        unanswered.failure = .network
        var check = RecoveryOpenState(step: .check)
        check.pin = "975310"
        check.password = "pw"
        let steps: [(String, RecoveryOpenState)] = [
            ("enter", RecoveryOpenState()), ("answered", answered), ("unanswered", unanswered), ("check", check),
            ("finish", RecoveryOpenState(step: .finish)),
        ]
        for (name, s) in steps {
            for (problem, expected) in [(OpenSideNotice.guidance(.tryOpenAgain), "guidance"), (.failure(.network), "error")] {
                let seen = ActionLog()
                let window = host(
                    RecoveryOpenContent(state: s, problem: problem, noticeProbe: { seen.items.append($0) }, onStartOver: {})
                )
                #expect(seen.items.filter { $0 == "guidance" || $0 == "error" } == [expected], "\(name), \(expected)")
                window.isHidden = true
            }
            // While the abandon runs the steps with a Send or Continue take no input.
            if s.step == .check || s.step == .enter {
                let seen = ActionLog()
                let busy = host(RecoveryOpenContent(state: s, problem: nil, busy: true, noticeProbe: { seen.items.append($0) }, onStartOver: {}))
                #expect(seen.items.contains("busy"), "\(name)")
                busy.isHidden = true
                let idle = ActionLog()
                let free = host(RecoveryOpenContent(state: s, problem: nil, noticeProbe: { idle.items.append($0) }, onStartOver: {}))
                #expect(!idle.items.contains("busy"), "\(name)")
                free.isHidden = true
            }
        }
    }

    /// After a recovery that already succeeded on this phone the PIN finishes it, and nothing is started over.
    @Test func anAlreadyRecoveredPhoneFinishesWithThePin() {
        // "Start over" is on the fields, and gone while the recovery already succeeded on this phone.
        for (problem, shown) in [(nil, true), (OpenSideNotice.guidance(.alreadyRecovered), false), (.guidance(.tryOpenAgain), true)] {
            let seen = ActionLog()
            let window = host(RecoveryOpenContent(state: RecoveryOpenState(), problem: problem, noticeProbe: { seen.items.append($0) }, onStartOver: {}))
            #expect(seen.items.contains("start_over") == shown, "\(String(describing: problem))")
            window.isHidden = true
        }
        // The guidance has an action (the finish) and hides "Start over": the text link stands in its card.
        #expect(GuidanceNotice.offersFinish(.alreadyRecovered) && GuidanceNotice.offersFinish(.finishWithPin))
        #expect(GuidanceNotice.offersFinish(.tryOpenAgain) && !GuidanceNotice.offersFinish(.retry) && !GuidanceNotice.offersFinish(.startOverFirst))
    }

    // MARK: - The code editor

    /// What the model refuses does not stay in the view, also when the model did not change; Return continues only when Continue
    /// is enabled; the cursor keeps its place when the text is drawn again in groups.
    @Test func theEditorShowsTheModelsTextReturnSubmitsAndTheCursorStays() async throws {
        let vault = FakeVaultRepository(.setup(.vaultElsewhere))
        let model = RecoverViewModel(move: vault, vault: vault, account: vault)
        await model.settle()
        model.type()
        let window = host(
            RecoverRoute(move: vault, vault: vault, account: vault, onLeave: {}, onNewVault: {}, onOpenAccountSite: {}, camera: nil, model: model)
        )
        let editor = try #require(views(in: window).compactMap { $0 as? UITextView }.first)
        for _ in 0..<2 {
            editor.text = "7ZK3U"
            editor.delegate?.textViewDidChange?(editor)
            let shown = await eventually { editor.text == "7ZK3" && model.state.typed == "7ZK3" }
            #expect(shown, "the refused U does not stay, the second time either")
        }
        let range = NSRange(location: 0, length: 0)
        let incomplete = editor.delegate?.textView?(editor, shouldChangeTextIn: range, replacementText: "\n")
        #expect(incomplete == false && vault.calls.filter { $0 == "registerTypedRecovery" }.isEmpty)
        window.isHidden = true
        // The cursor: after the same characters, not at the end.
        let v = UITextView()
        v.text = "7ZK3M9"
        v.selectedRange = NSRange(location: 3, length: 0)
        SecretTextView.show("7ZK3 M9", in: v)
        #expect(v.text == "7ZK3 M9" && v.selectedRange.location == 3)
        v.selectedRange = NSRange(location: 4, length: 0)
        SecretTextView.show("7ZK3 M9QX", in: v)
        #expect(v.selectedRange.location == 4)
        v.text = "7ZK3M9"
        v.selectedRange = NSRange(location: 6, length: 0)
        SecretTextView.show("7ZK3 M9", in: v)
        #expect(v.selectedRange.location == 7)
    }

    /// The code keyboard's own characters.
    @Test func theTypedFieldKeepsDigitsAndLettersOnly() {
        for kept in ["7", "Z", "z", "I", "l", "O", "0"] { #expect(RecoverState.keepsTyped(Character(kept)), "\(kept)") }
        for dropped in ["U", "u", "-", " ", "\n", "."] { #expect(!RecoverState.keepsTyped(Character(dropped)), "\(dropped)") }
    }

    // MARK: - The routes

    /// The back arrow leaves the recovery only where nothing is registered or under way.
    @Test func onlyTheStartLeavesTheRecovery() {
        let leaves: Set<RecoverStep> = [.intro, .loading, .stageFailed]
        for step in RecoverStep.allCases {
            #expect(RecoverContent.leaveable(step) == leaves.contains(step), "\(step)")
        }
    }

    /// The route owns its model: the typed code is forgotten when the screen goes, and the registration it made stays.
    @Test func theRouteForgetsTheCodeWhenItGoes() async throws {
        let vault = FakeVaultRepository(.setup(.vaultElsewhere))
        let model = RecoverViewModel(move: vault, vault: vault, account: vault)
        await model.settle()
        model.type()
        model.setTyped("7ZK3M9QX")
        #expect(model.state.typed == "7ZK3M9QX")
        var window: UIWindow? = host(
            RecoverRoute(move: vault, vault: vault, account: vault, onLeave: {}, onNewVault: {}, onOpenAccountSite: {}, camera: nil, model: model)
        )
        #expect(window != nil)
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
        let forgotten = await eventually { model.state.typed.isEmpty }
        #expect(forgotten)
        #expect(!vault.calls.contains("abandonRecovery"), "leaving the screen forgets nothing the vault holds")
    }

    /// The open pane's route drops the PIN and the password when it goes.
    @Test func theOpenRouteForgetsTheEntriesWhenItGoes() async throws {
        let vault = FakeVaultRepository(.setup(.recovering))
        vault.phoneSecret = true
        let model = RecoveryOpenViewModel(move: vault, account: vault)
        await model.settle()
        model.setPin("975310")
        model.setPassword("pw")
        var window: UIWindow? = host(RecoveryOpenRoute(move: vault, account: vault, problem: nil, onStartOver: {}, onOpened: {}, model: model))
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
        let forgotten = await eventually { model.state.pin.isEmpty && model.state.password.isEmpty }
        #expect(forgotten)
    }

    /// The flow's recover route is the screen, and the app's routes carry it.
    @Test func theMovesRoutesCarryTheRecovery() {
        let vault = FakeVaultRepository(.setup(.vaultElsewhere))
        let routes = OnboardingRoutes.moves(move: vault, vault: vault, account: vault)
        let view = routes.recover({}, {}, {})
        #expect(height(view) > 0)
    }

    // MARK: - Helpers

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }

    private func textFields(in view: UIView) -> [UITextField] { views(in: view).compactMap { $0 as? UITextField } }

    private func eventually(within: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: within)
        while clock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class ActionLog {
    var items: [String] = []
}

// swiftlint:enable line_length
#endif
