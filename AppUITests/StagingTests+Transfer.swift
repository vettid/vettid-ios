import XCTest

/// The transfer to a new phone on staging (VAULT-MESSAGING §6.7.1, §11.14.10; IOS-PLAN I3.3): ``testStagingTransferOut``
/// on the old phone (Settings → Security → "Move to a new phone"), ``testStagingTransferIn`` on a fresh new phone (the
/// welcome screen's "Move from my old phone", then "Finish the move"). Either phone can be an iPhone or an Android phone
/// (the Android app's own staging tests are the counterpart). Both are run at the same time: the old phone first, which
/// reports the transfer code (a link) on a `TRANSFER_LINK:` line; the new phone is given it as
/// `VETTID_STAGING_TRANSFER_CODE`. Both report their safety code on a `SAFETY_CODE:` line; a person compares them on the
/// two phones and taps "The codes match" (or "Reject") on the old phone, which never approves by itself (unless
/// the script's `--auto-match`, which prints `TRANSFER_SAS_UNCHECKED`). The outcome is on a `TRANSFER_STATE:`
/// line. The code is valid for a few minutes and works once; it is never printed
/// except on the old phone's `TRANSFER_LINK:` line, which is its purpose. No failure message carries it.
extension StagingTests {
    /// The seconds a transfer step waits for the other phone (`VETTID_STAGING_TRANSFER_TIMEOUT`, 300 without it, which is
    /// the code's own window).
    static func transferWait() throws -> TimeInterval { try seconds("VETTID_STAGING_TRANSFER_TIMEOUT", fallback: 300) }

    /// The `TRANSFER_STATE:` line: the state alone.
    static func report(transferState state: String) { print("TRANSFER_STATE: \(state)") }

    /// The first of [ids] shown, or "error" / "transfer_error" when a failure notice shows first; nil after [timeout].
    @MainActor
    private func transferStep(_ app: XCUIApplication, _ ids: [String], timeout: TimeInterval) -> String? {
        var found: String?
        _ = waitUntil(timeout: timeout) {
            let screen = shown(app)
            if let id = ids.first(where: { screen[$0] != nil }) {
                found = id
                return true
            }
            found = ["transfer_error", "error"].first { screen[$0] != nil }
            return found != nil
        }
        return found
    }

    /// The transfer code as the link's own element shows it (`transfer_link`), nil if it cannot be read.
    @MainActor
    private func transferLink(_ app: XCUIApplication) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        guard let box = ordered(under: root).first(where: { $0.identifier == "transfer_link" }) else { return nil }
        for e in [box] + ordered(under: box) {
            for text in [e.label, (e.value as? String) ?? ""] where text.hasPrefix("https://") {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// The safety code on screen (within 30 s), reported; nil when none shows.
    @MainActor
    private func reportedSafetyCode(_ app: XCUIApplication) -> String? {
        var found: String?
        _ = waitUntil(timeout: 30) {
            found = safetyCode(in: app)
            return found != nil
        }
        if let found { report(safetyCode: found) }
        return found
    }

    /// Prints [line] and flushes at once, so that it reaches the operator while the test goes on.
    static func say(_ line: String) {
        print(line)
        fflush(stdout)
    }

    /// What a transfer test was given: the PIN, the password (optional on the new phone), whether the old phone may tap
    /// "The codes match" itself (the script's `--auto-match`), and the wait.
    struct TransferInputs {
        let pin: String
        let password: String?
        let autoMatch: Bool
        let limit: TimeInterval
    }

    /// The states that count as a finished move.
    static let movedStates: Set<String> = ["moved", "moved_unlocked", "moved_locked"]

    // MARK: - The new phone

    /// A fresh app (`--fresh` is for the enrollment only: remove the app by hand, or use a phone that never enrolled):
    /// "Move from my old phone" → "Type or paste the code" with `VETTID_STAGING_TRANSFER_CODE`, the safety code
    /// reported, the wait (up to `VETTID_STAGING_TRANSFER_TIMEOUT`) for the old phone's approval, then "Finish the move"
    /// with the PIN. The result is a `TRANSFER_STATE:` line: `moved_unlocked` (the vault is open on this phone; it is then
    /// locked), `moved_locked`, `moved` (a move without a phone secret, the next screen confirmed), or what stopped it:
    /// `code_refused`, `no_safety_code`, `rejected`, `timed_out`, `not_answered`, `finish_held`, `finish_failed`,
    /// `owner_check`, `owner_check_failed`, `moved_unconfirmed`, `error`, `none`. A handshake left open is cancelled first.
    @MainActor
    func testStagingTransferIn() throws {
        let pin = try Self.pin()
        let code = try Self.input("VETTID_STAGING_TRANSFER_CODE")
        let limit = try Self.transferWait()
        let password = ProcessInfo.processInfo.environment["VETTID_STAGING_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 }

        let app = launch()
        guard waitForAny(app, ["welcome_recover", "unlock", "app_shell", "owner_check"], timeout: 60) == "welcome_recover" else {
            return fail(app, "Not a fresh app: it shows a vault or no known screen. Remove VettID Staging first.")
        }
        continueAfterFailure = true
        let state = moveIn(app, code: code, TransferInputs(pin: pin, password: password, autoMatch: false, limit: limit))
        Self.report(transferState: state)
        if state == "moved_unlocked" { lock(app) }
        if !Self.movedStates.contains(state) { fail(app, "The move did not finish: \(state).") }
    }

    /// The new phone's steps; the state to report.
    @MainActor
    private func moveIn(_ app: XCUIApplication, code: String, _ inputs: TransferInputs) -> String {
        tap(app.buttons["form_secondary"])
        expect(app, "transfer_in", timeout: 30)
        tap(app.buttons["form_secondary"])
        expect(app, "transfer_in_paste", timeout: 30)
        let editor = app.textViews.firstMatch.waitForExistence(timeout: 10) ? app.textViews.firstMatch : anyElement(app, "transfer_code")
        guard editor.waitForExistence(timeout: 10) else { return "none" }
        editor.tap()
        editor.typeText(code)
        dismissKeyboard(app)
        tapPrimary(app)

        // The handshake with the old phone's vault, then the safety code to compare.
        switch transferStep(app, ["transfer_in_compare", "code_refused"], timeout: Self.handshake) {
        case "transfer_in_compare": break
        case "code_refused": return "code_refused"
        default: return abandoned(app, "error")
        }
        guard reportedSafetyCode(app) != nil else { return abandoned(app, "no_safety_code") }
        return awaitApproval(app, inputs)
    }

    /// A handshake that is not going to finish is cancelled ("Cancel" of the connecting and the compare screens), and the
    /// screen is waited for to go, so that the old phone's vault is not left with it; [state] is returned.
    @MainActor
    private func abandoned(_ app: XCUIApplication, _ state: String) -> String {
        let open = ["transfer_in_compare", "transfer_in_connecting"]
        guard open.contains(where: { shown(app)[$0] != nil }) else { return state }
        tap(app.buttons["form_secondary"])
        if !waitUntil(timeout: 30, { let s = shown(app); return !s.isEmpty && open.allSatisfy { s[$0] == nil } }) {
            fail(app, "The handshake could not be cancelled.")
        }
        return state
    }

    /// The old phone's approval, and what follows it.
    @MainActor
    private func awaitApproval(_ app: XCUIApplication, _ inputs: TransferInputs) -> String {
        let ends = ["finish_move", "moved", "transfer_rejected", "transfer_timed_out", "transfer_not_answered"]
        switch transferStep(app, ends, timeout: inputs.limit) {
        case "finish_move": return finishMove(app, inputs)
        case "moved": return afterMove(app, tapGo: true, inputs)
        case "transfer_rejected": return "rejected"
        case "transfer_timed_out": return "timed_out"
        case "transfer_not_answered": return "not_answered"
        case nil: return abandoned(app, "none")
        default: return abandoned(app, "error")
        }
    }

    /// "Finish the move": the PIN on the keypad (nothing is sent unless it holds all the digits), then the result.
    @MainActor
    private func finishMove(_ app: XCUIApplication, _ inputs: TransferInputs) -> String {
        guard enterPin(app, inputs.pin) else { return "finish_failed" }
        let go = app.buttons["finish_move_go"]
        guard waitUntil(timeout: 30, { go.exists && go.isEnabled && go.isHittable }) else { return "finish_held" }
        go.tap()
        // The lock and the unlock on this phone run inside (minutes at most).
        switch transferStep(app, ["finish_move_continue", "finish_move_failure", "finish_move_held"], timeout: Self.network * 3) {
        case "finish_move_continue": return afterMove(app, tapGo: false, inputs)
        case "finish_move_held": return "finish_held"
        default: return "finish_failed"
        }
    }

    /// Leaves the move's last screen ("Continue" of the finished move, or the move's own "go" of a move without a phone
    /// secret) and reports where the app ends once that screen is confirmed: `moved_unlocked`, `moved_locked` (after
    /// "Continue"), `moved` (after the move's own screen, the unlock screen shown), `owner_check` (no password given),
    /// `owner_check_failed`, or `moved_unconfirmed` (no button, or no following screen).
    @MainActor
    private func afterMove(_ app: XCUIApplication, tapGo: Bool, _ inputs: TransferInputs) -> String {
        let button = tapGo ? app.buttons["form_primary"] : app.buttons["finish_move_continue"]
        guard button.waitForExistence(timeout: 10) else { return "moved_unconfirmed" }
        button.tap()
        switch waitForAny(app, ["app_shell", "unlock", "owner_check"], timeout: Self.network) {
        case "app_shell": return "moved_unlocked"
        case "unlock": return tapGo ? "moved" : "moved_locked"
        case "owner_check":
            guard let password = inputs.password else { return "owner_check" }
            return ownerCheck(app, pin: inputs.pin, password: password) ? "moved_unlocked" : "owner_check_failed"
        default: return "moved_unconfirmed"
        }
    }

    // MARK: - The old phone

    /// The unlocked app: Settings → Security → "Move to a new phone" → start; the code's link handed to the new phone on a
    /// `TRANSFER_LINK:` line (as ``testStagingInvite`` does with an invitation); the wait (up to
    /// `VETTID_STAGING_TRANSFER_TIMEOUT`) for the new phone to connect; its safety code reported on a `SAFETY_CODE:` line,
    /// with a `TRANSFER_OPERATOR:` line asking for the comparison. The test then waits (up to the same time) for a person
    /// to tap "The codes match" or "Reject" on this iPhone: it never approves by itself, except with the explicit opt-in
    /// the script's `--auto-match` (then `TRANSFER_SAS_UNCHECKED` is printed). After the match, the change of
    /// signer accepted when shown (a move across platforms), the PIN on the keypad and the credential password, and the
    /// approval. Reported on a `TRANSFER_STATE:` line: `moved` (the approval went through; `TRANSFER_AFTER:` then says
    /// what this phone shows: `kept` when the moved screen says the keys stay until the new phone has finished (release R:
    /// the test taps nothing more and never locks, the vault is the new phone's to finish), `welcome` or `welcome_notice`
    /// when the app erased itself, `none`), `rejected`, `expired`, `no_decision`, `no_link`, `no_phone`, `no_safety_code`, `approve_failed`, `approve_unknown` (after the tap on "Move"), `error`, `none`. After any
    /// other state the vault is locked only when a screen from before the approval shows and "Move" was never confirmed: a
    /// stuck confirmation, an approval still running or one of unknown outcome leaves the vault unlocked (a lock is never
    /// sent after a successful or possible approval).
    @MainActor
    func testStagingTransferOut() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let limit = try Self.transferWait()
        // Only the script's `--auto-match` sets this.
        let auto = ProcessInfo.processInfo.environment["VETTID_STAGING_TRANSFER_AUTO_MATCH"] == "1"

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        openSettings(app)
        let row = anyElement(app, "transfer")
        var state = "none"
        if reveal(app, row) {
            row.tap()
            state = moveOut(app, TransferInputs(pin: pin, password: password, autoMatch: auto, limit: limit))
        }
        if state != "moved" {
            // Settle first: an approval that was still running may have gone through since.
            // After "Move" was confirmed, whatever the outcome, nothing is locked.
            switch settledOut(app, mayLock: state != "approve_unknown") {
            case .moved:
                state = afterApproval(app)
            case .quiet:
                Self.report(transferState: state)
                lock(app)
                return fail(app, "The move did not happen: \(state).")
            case .stuck:
                Self.report(transferState: state)
                return fail(app, "The move did not happen: \(state).")
            }
        }
        Self.report(transferState: state)
    }

    /// The old phone's steps; the state to report.
    @MainActor
    private func moveOut(_ app: XCUIApplication, _ inputs: TransferInputs) -> String {
        guard waitForAny(app, ["transfer_intro"], timeout: 30) != nil else { return "none" }
        tapPrimary(app)
        guard transferStep(app, ["transfer_showing"], timeout: Self.network) == "transfer_showing" else { return "error" }
        var link: String?
        _ = waitUntil(timeout: 30) {
            link = transferLink(app)
            return link != nil
        }
        // The code is handed to the new phone: this line is what the script leaves in clear.
        Self.say("TRANSFER_LINK: \(link ?? "none")")
        guard link != nil else { return "no_link" }

        switch transferStep(app, ["transfer_compare", "transfer_expired"], timeout: inputs.limit) {
        case "transfer_compare": break
        case "transfer_expired": return "expired"
        case nil: return "no_phone"
        default: return "error"
        }
        guard reportedSafetyCode(app) != nil else { return "no_safety_code" }
        return decideOut(app, inputs)
    }

    /// The comparison, by a person (or the explicit opt-in), and what follows it.
    @MainActor
    private func decideOut(_ app: XCUIApplication, _ inputs: TransferInputs) -> String {
        if inputs.autoMatch {
            Self.say("TRANSFER_SAS_UNCHECKED")
            tapPrimary(app)
        } else {
            Self.say("TRANSFER_OPERATOR: compare the safety codes on both phones and tap on this iPhone")
        }
        // A person decides: "The codes match" goes on to the signer or the PIN, "Reject" ends the transfer.
        let next = ["transfer_signer", "transfer_approve", "transfer_rejected", "transfer_expired"]
        switch transferStep(app, next, timeout: inputs.limit) {
        case "transfer_rejected": return "rejected"
        case "transfer_expired": return "expired"
        case nil: return "no_decision"
        case let step?: return approveOut(app, inputs, step: step)
        }
    }

    /// Taps the confirmation alert's button, by its identifier or else by its [label], and waits for the alert to close.
    @MainActor
    private func confirmAlert(_ app: XCUIApplication, label: String) -> Bool {
        let byId = anyElement(app, "confirm_button")
        let button = byId.waitForExistence(timeout: 10) ? byId : app.alerts.buttons[label]
        guard button.waitForExistence(timeout: 10) else { return false }
        button.tap()
        return waitUntil(timeout: 10) { !app.alerts.firstMatch.exists }
    }

    /// From the screen after the match ([step]): the change of signer, then the PIN and the password, and the approval.
    @MainActor
    private func approveOut(_ app: XCUIApplication, _ inputs: TransferInputs, step first: String) -> String {
        var step: String? = first
        if step == "transfer_signer" {
            Self.say("TRANSFER_SIGNER: shown")
            tapPrimary(app)
            step = transferStep(app, ["transfer_approve", "transfer_rejected"], timeout: Self.network)
        }
        guard step == "transfer_approve" else { return step == "transfer_rejected" ? "rejected" : "error" }
        // Nothing is sent unless the keypad holds the whole PIN.
        guard enterPin(app, inputs.pin) else { return "approve_failed" }
        let field = app.secureTextFields["transfer_password"]
        tap(field)
        field.typeText(inputs.password ?? "")
        dismissKeyboard(app)
        tapPrimary(app)
        // From the tap on "Move" the approval may be on its way: any outcome but the end screens is unknown.
        guard confirmAlert(app, label: "Move") else { return "approve_unknown" }
        failOnSavePassword(app)

        // A wiped phone erases itself to the welcome screen and never shows the moved screen.
        let ends = ["transfer_moved", "welcome_recover", "transfer_rejected", "transfer_expired"]
        switch transferStep(app, ends, timeout: Self.network * 2) {
        case "welcome_recover": return movedAway(app)
        case "transfer_moved": return afterApproval(app)
        case "transfer_rejected": return "rejected"
        case "transfer_expired": return "expired"
        default: return "approve_unknown"
        }
    }

    /// Where the old phone stands once nothing is in flight.
    private enum Settled {
        /// The moved screen or the welcome screen shows: the approval went through. Nothing is tapped, nothing is locked.
        case moved
        /// A screen from before the approval shows and "Move" was never confirmed: the vault can be locked.
        case quiet
        /// A confirmation could not be cancelled, or the approval never settled: nothing is locked (the failure is recorded).
        case stuck
    }

    /// Before a cleanup lock: a confirmation left open is cancelled (by its "Cancel" label, never by position), and the
    /// approval is waited for if it is in flight (its Reject is disabled while it runs; Back would send a reject that races
    /// it). Then the screen is read again: a moved screen means the approval went through.
    @MainActor
    private func settledOut(_ app: XCUIApplication, mayLock: Bool) -> Settled {
        let alert = app.alerts.firstMatch
        if alert.exists {
            let cancel = alert.buttons["Cancel"]
            guard cancel.exists else {
                fail(app, "A confirmation is open and has no Cancel button: the vault was not locked.")
                return .stuck
            }
            cancel.tap()
            _ = waitUntil(timeout: 10) { !alert.exists }
        }
        let reject = app.buttons["form_secondary"]
        let settled = waitUntil(timeout: Self.network * 2) {
            let screen = shown(app)
            return !screen.isEmpty && (screen["transfer_approve"] == nil || (reject.exists && reject.isEnabled))
        }
        guard settled else {
            fail(app, "The approval is still running: the vault was not locked.")
            return .stuck
        }
        // A screen between two others (the moved screen erasing itself) shows neither: read again once.
        for attempt in 0..<2 {
            let screen = shown(app)
            if screen["transfer_moved"] != nil || screen["welcome_recover"] != nil { return .moved }
            let before = ["transfer_intro", "transfer_showing", "transfer_compare", "transfer_signer", "transfer_rejected",
                          "transfer_expired"].contains { screen[$0] != nil }
            let approveIdle = screen["transfer_approve"] != nil && reject.exists && reject.isEnabled
            if mayLock && (before || approveIdle) { return .quiet }
            if attempt == 0 { Thread.sleep(forTimeInterval: 2) }
        }
        fail(app, "The screen is not one before the approval: the vault was not locked.")
        return .stuck
    }

    /// The approval went through and the app erased itself: where it ended is reported.
    @MainActor
    private func movedAway(_ app: XCUIApplication) -> String {
        Self.say("TRANSFER_AFTER: \(shown(app)["vault_deleted_notice"] != nil ? "welcome_notice" : "welcome")")
        return "moved"
    }

    /// Whether the moved screen says the keys are kept: the text is on an element under the screen's container, whose own
    /// label is empty.
    @MainActor
    private func movedScreenKeepsKeys(_ app: XCUIApplication) -> Bool {
        guard let root = try? app.snapshot() else { return false }
        guard let screen = ordered(under: root).first(where: { $0.identifier == "transfer_moved" }) else { return false }
        return ([screen] + ordered(under: screen)).contains { $0.label.contains("Finish the move on your new phone") }
    }

    /// The moved screen. Nothing is tapped and nothing is locked: the new phone finishes the move, and a lock or a Back
    /// from here could race it. On release R the screen says the keys are kept (`TRANSFER_AFTER: kept`); otherwise the phone
    /// erases itself, which is waited for (`welcome`), or `none` is reported.
    @MainActor
    private func afterApproval(_ app: XCUIApplication) -> String {
        if movedScreenKeepsKeys(app) {
            Self.say("TRANSFER_AFTER: kept")
            return "moved"
        }
        var wiped = false
        _ = waitUntil(timeout: Self.network) {
            wiped = shown(app)["welcome_recover"] != nil
            return wiped
        }
        if wiped { return movedAway(app) }
        Self.say("TRANSFER_AFTER: none")
        return "moved"
    }
}
