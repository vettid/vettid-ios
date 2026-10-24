import XCTest

/// The transfer to a new phone on staging (VAULT-MESSAGING §6.7.1, §11.14.10; IOS-PLAN I3.3): ``testStagingTransferOut``
/// on the old phone (Settings → Security → "Move to a new phone"), ``testStagingTransferIn`` on a fresh new phone (the
/// welcome screen's "Move from my old phone", then "Finish the move"). Either phone can be an iPhone or an Android phone
/// (the Android app's own staging tests are the counterpart). Both are run at the same time: the old phone first, which
/// reports the transfer code (a link) on a `TRANSFER_LINK:` line; the new phone is given it as
/// `VETTID_STAGING_TRANSFER_CODE`. Both report their safety code on a `SAFETY_CODE:` line, which the operator compares,
/// and the outcome on a `TRANSFER_STATE:` line. The code is valid for a few minutes and works once; it is never printed
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

    /// What a transfer test was given: the PIN, the password (optional on the new phone), the safety code the other phone
    /// shows when known, and the wait.
    struct TransferInputs {
        let pin: String
        let password: String?
        let expected: String?
        let limit: TimeInterval
    }

    // MARK: - The new phone

    /// A fresh app (`--fresh` is for the enrollment only: remove the app by hand, or use a phone that never enrolled):
    /// "Move from my old phone" → "Type or paste the code" with `VETTID_STAGING_TRANSFER_CODE`, the safety code
    /// reported (compared with `VETTID_STAGING_SAFETY_CODE` when that is set), the wait (up to
    /// `VETTID_STAGING_TRANSFER_TIMEOUT`) for the old phone's approval, then "Finish the move" with the PIN. The result is
    /// a `TRANSFER_STATE:` line: `moved_unlocked` (the vault is open on this phone; it is then locked), `moved_locked`,
    /// `moved` (a move without a phone secret), or what stopped it: `code_refused`, `no_safety_code`, `code_mismatch`,
    /// `rejected`, `timed_out`, `not_answered`, `finish_held`, `finish_failed`, `owner_check`, `error`, `none`.
    @MainActor
    func testStagingTransferIn() throws {
        let pin = try Self.pin()
        let code = try Self.input("VETTID_STAGING_TRANSFER_CODE")
        let expected = try Self.optionalSafetyCode()
        let limit = try Self.transferWait()
        let password = ProcessInfo.processInfo.environment["VETTID_STAGING_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 }

        let app = launch()
        guard waitForAny(app, ["welcome_recover", "unlock", "app_shell", "owner_check"], timeout: 60) == "welcome_recover" else {
            return fail(app, "Not a fresh app: it shows a vault or no known screen. Remove VettID Staging first.")
        }
        continueAfterFailure = true
        let inputs = TransferInputs(pin: pin, password: password, expected: expected, limit: limit)
        let state = moveIn(app, code: code, inputs)
        Self.report(transferState: state)
        if state == "moved_unlocked" { lock(app) }
        if !state.hasPrefix("moved") { fail(app, "The move did not finish: \(state).") }
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
        default: return "error"
        }
        guard let sas = reportedSafetyCode(app) else { return "no_safety_code" }
        if let expected = inputs.expected, expected != sas { return "code_mismatch" }

        return awaitApproval(app, inputs)
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
        case nil: return "none"
        default: return "error"
        }
    }

    /// "Finish the move": the PIN on the keypad, then the result.
    @MainActor
    private func finishMove(_ app: XCUIApplication, _ inputs: TransferInputs) -> String {
        enterPin(app, inputs.pin)
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

    /// Leaves the move's last screen ("Continue" of the finished move, or the move's own "go") and reports where the app
    /// ends: `moved_unlocked`, `moved_locked`, `owner_check` (no password given) or `moved`.
    @MainActor
    private func afterMove(_ app: XCUIApplication, tapGo: Bool, _ inputs: TransferInputs) -> String {
        let button = tapGo ? app.buttons["form_primary"] : app.buttons["finish_move_continue"]
        if button.waitForExistence(timeout: 10) { button.tap() }
        switch waitForAny(app, ["app_shell", "unlock", "owner_check"], timeout: Self.network) {
        case "app_shell": return "moved_unlocked"
        case "unlock": return "moved_locked"
        case "owner_check":
            guard let password = inputs.password else { return "owner_check" }
            ownerCheck(app, pin: inputs.pin, password: password)
            return "moved_unlocked"
        default: return "moved"
        }
    }

    // MARK: - The old phone

    /// The unlocked app: Settings → Security → "Move to a new phone" → start; the code's link handed to the new phone on a
    /// `TRANSFER_LINK:` line (as ``testStagingInvite`` does with an invitation); the wait (up to
    /// `VETTID_STAGING_TRANSFER_TIMEOUT`) for the new phone to connect; its safety code reported, and compared with
    /// `VETTID_STAGING_SAFETY_CODE` when that is set (a different code rejects the transfer: nothing is approved). Without
    /// it the operator compares the two phones' `SAFETY_CODE:` lines, and a run whose lines differ is not valid. Then the
    /// match confirmed, the change of signer accepted when shown (a move across platforms), the PIN on the keypad and the
    /// credential password, and the approval. Reported on a `TRANSFER_STATE:` line: `moved` (the vault left this phone),
    /// `code_mismatch`, `expired`, `rejected`, `no_link`, `no_phone`, `no_safety_code`, `approve_failed`, `error`, `none`. A
    /// vault that stays on this phone is locked at the end.
    @MainActor
    func testStagingTransferOut() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let expected = try Self.optionalSafetyCode()
        let limit = try Self.transferWait()

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        openSettings(app)
        let row = anyElement(app, "transfer")
        var state = "none"
        if reveal(app, row) {
            row.tap()
            state = moveOut(app, TransferInputs(pin: pin, password: password, expected: expected, limit: limit))
        }
        Self.report(transferState: state)
        if state != "moved" { lock(app) }
        if state != "moved" { fail(app, "The move did not happen: \(state).") }
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
        print("TRANSFER_LINK: \(link ?? "none")")
        guard link != nil else { return "no_link" }

        switch transferStep(app, ["transfer_compare", "transfer_expired"], timeout: inputs.limit) {
        case "transfer_compare": break
        case "transfer_expired": return "expired"
        case nil: return "no_phone"
        default: return "error"
        }
        guard let sas = reportedSafetyCode(app) else { return "no_safety_code" }
        if let expected = inputs.expected, expected != sas {
            // Not the new phone the member expects: the transfer is rejected, and nothing is approved.
            tap(app.buttons["form_secondary"])
            tap(anyElement(app, "confirm_button"))
            return "code_mismatch"
        }
        tapPrimary(app)
        return approveOut(app, inputs)
    }

    /// After the match: the change of signer (a move between platforms), then the PIN and the password, and the approval.
    @MainActor
    private func approveOut(_ app: XCUIApplication, _ inputs: TransferInputs) -> String {
        var step = transferStep(app, ["transfer_signer", "transfer_approve", "transfer_rejected"], timeout: Self.network)
        if step == "transfer_signer" {
            print("TRANSFER_SIGNER: shown")
            tapPrimary(app)
            step = transferStep(app, ["transfer_approve", "transfer_rejected"], timeout: Self.network)
        }
        guard step == "transfer_approve" else { return step == "transfer_rejected" ? "rejected" : "error" }
        enterPin(app, inputs.pin)
        let field = app.secureTextFields["transfer_password"]
        tap(field)
        field.typeText(inputs.password ?? "")
        dismissKeyboard(app)
        tapPrimary(app)
        tap(anyElement(app, "confirm_button"))
        failOnSavePassword(app)

        switch transferStep(app, ["transfer_moved", "transfer_rejected", "transfer_expired"], timeout: Self.network * 2) {
        case "transfer_moved":
            // Done leaves the screen; the vault is no longer on this phone.
            if app.buttons["form_primary"].waitForExistence(timeout: 10) { app.buttons["form_primary"].tap() }
            return "moved"
        case "transfer_rejected": return "rejected"
        case "transfer_expired": return "expired"
        default: return "approve_failed"
        }
    }
}
