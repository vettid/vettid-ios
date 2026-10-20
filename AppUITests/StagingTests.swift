import XCTest

/// Staging end to end on a real iPhone (STAGING-TESTING §3 "Enrolling a phone", §5), the counterpart of vettid-android's
/// automated staging tests. Run with the `VettIDStagingUITests` scheme (the Staging build) through
/// `scripts/staging-ui-test.sh`, which hands the inputs to the test runner at run time:
///
/// - `VETTID_STAGING_EMAIL`: the test member's address;
/// - `VETTID_STAGING_CODE`: the 8-character code from the account site's "Enroll a phone" (it lives 5 minutes);
/// - `VETTID_STAGING_PIN`: the vault PIN;
/// - `VETTID_STAGING_PASSWORD`: the credential password;
/// - `VETTID_STAGING_LINK`: another member's invitation link, for ``testStagingConnectAccept``;
/// - `VETTID_STAGING_SAFETY_CODE`: optional, the safety code ``testStagingConnectApprove`` must find.
///
/// A test whose inputs are missing is skipped, so CI and every other run never execute it. The inputs are never printed
/// and no failure message carries them (XCTest's own activity log names what is typed and tapped: the script redacts its
/// output and keeps the result bundle private).
final class StagingTests: XCTestCase {
    /// Network steps: a redeem, an unlock, a lock.
    static let network: TimeInterval = 90
    /// Enrollment: the vault's enclave is made and attested, then the credential.
    private static let enrollment: TimeInterval = 600
    /// What the test of a wrong PIN appends to the current password to make its new one (never sent with the right PIN).
    private static let wrongPinSuffix = " wrong-pin"
    /// The vault's `bad_pin` refusal on a form (`data_failure_bad_pin`, the only localization being English).
    private static let badPinText = "That PIN is not correct."
    /// A release update: the lock, the unlock with the approval, and the unlock on the new release, which may have to
    /// start first (VAULT-MESSAGING §11.10.5: `503 release_starting`, minutes).
    private static let releaseUpdate: TimeInterval = 900

    /// Identifiers of the notices that say why something failed: their text is what a failure reports.
    static let failureIds = [
        "error", "scan_refused", "pin_error", "pin_confirm_error", "credential_pin_error", "unlock_failed", "unlock_refused",
        "unlock_preflight_error", "unlock_pin_error", "unlock_not_recognised", "unlock_stuck", "unlock_recover_only",
        "unlock_signer_refused", "unlock_owner_check_locked", "unlock_lock_unconfirmed", "move_back_failed",
        "owner_check_failed", "owner_check_pin_error", "failure",
    ]

    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { Self.savePasswordSeen = false }
    }

    // MARK: - Tests

    /// STAGING-TESTING §3: a fresh app, the typed code with the member's address, the PIN on the keypad, the credential
    /// password, the default backup, and the open app at the end.
    @MainActor
    func testStagingEnroll() throws {
        let email = try Self.input("VETTID_STAGING_EMAIL")
        let code = try Self.input("VETTID_STAGING_CODE")
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")

        let app = launch()
        let start = waitForAny(app, ["welcome_recover", "unlock", "app_shell"], timeout: 60)
        guard start == "welcome_recover" else {
            return fail(app, "Not a fresh app: \(start ?? "no known screen") is shown. Remove VettID Staging first (--fresh).")
        }

        // Welcome → scan (iOS asks for the camera here) → type the code instead.
        tap(app.buttons["form_primary"])
        allowSystemAlert()
        expect(app, "setup_scan", timeout: 30)
        tap(app.buttons["form_secondary"])
        let emailField = app.textFields["setup_email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 30), "the typed-code screen did not open")
        emailField.tap()
        emailField.typeText(email)
        let codeField = app.textFields["setup_code"]
        codeField.tap()
        codeField.typeText(code)
        tapPrimary(app)

        // The redeem (VAULT-MESSAGING §11.12.1): "Is this your account?", or the app's refusal.
        expect(app, "confirm_account", timeout: Self.network)
        tapPrimary(app)

        // The PIN and its confirmation, on the in-app keypad.
        expect(app, "pin", timeout: 30)
        enterPin(app, pin)
        tapPrimary(app)
        expect(app, "pin_confirm", timeout: 30)
        enterPin(app, pin)
        tapPrimary(app)

        // The credential password (release R also asks for the PIN here).
        let passwordField = app.secureTextFields["password"]
        if !passwordField.waitForExistence(timeout: 30) { return fail(app, "The password screen did not open.") }
        if shown(app)["credential_pin"] != nil { enterPin(app, pin) }
        passwordField.tap()
        passwordField.typeText(password)
        let confirmField = app.secureTextFields["password_confirm"]
        confirmField.tap()
        confirmField.typeText(password)
        let primary = app.buttons["form_primary"]
        if !waitUntil(timeout: 10, { primary.isEnabled }) {
            let rule = shown(app)["password_rule"] ?? ""
            return fail(app, "The password was not accepted: \(rule)")
        }
        if primary.isHittable { primary.tap() } else { confirmField.typeText("\n") }

        // The backup (on, the default) and the enrollment. No "Save Password?" may follow the password (IOS-PLAN §6.5).
        expect(app, "backup_on", timeout: 30)
        failOnSavePassword(app)
        tapPrimary(app)
        expect(app, "onboarding_done", timeout: Self.enrollment)
        tapPrimary(app)
        expect(app, "app_shell", timeout: Self.network)
    }

    /// Unlock with the PIN (and the password when the owner check is due), the open app, then "Lock vault" from the account
    /// sheet and the unlock screen again (STAGING-TESTING §5: a session ends with the vault locked).
    @MainActor
    func testStagingUnlockLock() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")

        let app = launch()
        let start = waitForAny(app, ["unlock", "app_shell", "owner_check", "welcome_recover"], timeout: 60)
        switch start {
        case "app_shell":
            // Already open: lock first, so that the unlock is tested.
            lock(app)
        case "owner_check":
            ownerCheck(app, pin: pin, password: password)
            lock(app)
        case "unlock":
            break
        default:
            return fail(app, "No vault on this phone to unlock: \(start ?? "no known screen") is shown.")
        }

        unlock(app, pin: pin, password: password)
        lock(app)
    }

    /// RELEASE-UPDATES §2: from the open app, Settings → Vault → "Update available", What's new and the release offered,
    /// "Approve and update" with the PIN; the lock, the unlock that carries the approval, the move, and the vault open on
    /// the new release. Then the vault is locked (STAGING-TESTING §5).
    @MainActor
    func testStagingApproveUpdate() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")

        let app = launch()
        switch waitForAny(app, ["unlock", "app_shell", "owner_check", "welcome_recover"], timeout: 60) {
        case "app_shell": break
        case "owner_check": ownerCheck(app, pin: pin, password: password)
        case "unlock": unlock(app, pin: pin, password: password)
        case let other: return fail(app, "No vault on this phone to update: \(other ?? "no known screen") is shown.")
        }

        // Settings, from the drawer; the row is there only while the vault has an update to approve.
        expect(app, "app_shell", timeout: Self.network)
        openSettings(app)
        let row = app.buttons["release_update_row"]
        if !row.waitForExistence(timeout: Self.network) {
            // Normal once the phone has moved: no newer active release in the manifest it uses.
            throw XCTSkip("Settings offers no release update.")
        }
        row.tap()
        expect(app, "release_offer", timeout: Self.network)
        enterPin(app, pin)
        tapPrimary(app)

        // The update's own screens: progress, then the outcome.
        let outcomes = ["release_update_done", "release_update_refused", "release_update_failed", "release_update_bad_pin",
                        "release_update_new_failed"]
        let outcome = waitForAny(app, outcomes, timeout: Self.releaseUpdate)
        guard outcome == "release_update_done" else {
            return fail(app, "The update did not finish: \(outcome ?? "still running after \(Int(Self.releaseUpdate)) s").")
        }
        tapPrimary(app)
        expect(app, "app_shell", timeout: Self.network)
        lock(app)
    }

    /// The unlock screen's own offer (§11.10.3): "Update available: release N" before the PIN, "Approve the update with
    /// this unlock", the PIN; the unlock carries the approval, the vault moves and the app opens on the new release. Then
    /// the vault is locked. Skipped when the unlock offers no update.
    @MainActor
    func testStagingApproveUpdateAtUnlock() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")

        let app = launch()
        guard lockedAtStart(app, pin: pin, password: password) else { return }
        guard shown(app)["release_offer"] != nil else { throw XCTSkip("The unlock screen offers no release update.") }
        let approve = app.switches["approve_offer"]
        tap(approve)
        if !waitUntil(timeout: 10, { (approve.value as? String) == "1" }) { return fail(app, "The approval could not be turned on.") }
        enterUnlock(app, pin: pin, password: password)
        // The unlock with the approval, the move, and the unlock that reaches the new release (which may start first).
        switch waitForAny(app, ["app_shell", "owner_check"], timeout: Self.releaseUpdate) {
        case "owner_check": ownerCheck(app, pin: pin, password: password)
        case "app_shell": break
        default: return fail(app, "The vault did not open on the new release.")
        }
        // Moved: Settings no longer offers the update (a refused update would still be offered).
        openSettings(app)
        let row = app.buttons["release_update_row"]
        if !waitUntil(timeout: Self.network, { !row.exists }) { return fail(app, "Settings still offers the update: it did not move.") }
        lock(app)
    }

    /// I1.8a's voluntary owner check (VAULT-MESSAGING §3.6.5): from the open app, Settings → the daily check's "Check
    /// now", the PIN on the keypad and the credential password; the check passes when its screen closes on Settings with
    /// no failure shown (the app has no success notice: the screen closes, as on vettid-android). Then the vault is
    /// locked (STAGING-TESTING §5).
    @MainActor
    func testStagingCheckNow() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        openSettings(app)
        let row = app.buttons["owner_check_now"]
        if !reveal(app, row) { return fail(app, "Settings has no \"Check now\": the vault has not reported its owner check.") }
        row.tap()

        expect(app, "owner_check_pin", timeout: 30)
        enterPin(app, pin)
        let field = app.secureTextFields["owner_check_password"]
        field.tap()
        field.typeText(password)
        tapPrimary(app)

        guard checkPassed(app, row: row) else { return }
        failOnSavePassword(app)
        lock(app)
    }

    /// Settings → Credential → Change password with a deliberately wrong PIN (the input PIN with its last digit changed),
    /// the current password and a new one the test makes up (the current password followed by
    /// ``wrongPinSuffix``); the vault refuses it (`bad_pin`, VAULT-MESSAGING §11.14.9) and the form shows "That PIN is not
    /// correct.". The form is then left without a retry, so the member's password is never changed, and the vault is
    /// locked. The right PIN is never sent with the change (the unlock uses it).
    ///
    /// A wrong PIN in a password change counts as a failed owner check (VAULT-MESSAGING §3.6.1, from 0.46.0; vettid-vault
    /// releases from staging 18), which the next passed check resets ("Check now" or the due check). Skipped (after the
    /// lock) when the change asks for no PIN (a vault without a phone secret).
    @MainActor
    func testStagingWrongPinInPasswordChange() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        guard let last = pin.last?.wholeNumberValue else { throw InputError.pinNotDigits }
        let wrongPin = String(pin.dropLast()) + String((last + 1) % 10)
        let newPassword = password + Self.wrongPinSuffix

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        guard let currentField = openPasswordChange(app) else { return }

        guard shown(app)["change_password_pin"] != nil else {
            tap(app.buttons["top_bar_back"].firstMatch)
            lock(app)
            throw XCTSkip("The password change asks for no PIN: the vault has no phone secret.")
        }
        enterPin(app, wrongPin)
        currentField.tap()
        currentField.typeText(password)
        let newField = app.secureTextFields["change_password_new"]
        newField.tap()
        newField.typeText(newPassword)
        let confirmField = app.secureTextFields["change_password_confirm"]
        confirmField.tap()
        confirmField.typeText(newPassword)
        let primary = app.buttons["form_primary"]
        if !waitUntil(timeout: 10, { primary.isEnabled }) {
            let rule = shown(app)["password_rule"] ?? ""
            return fail(app, "The new password was not accepted: \(rule)")
        }
        tapPrimary(app)

        guard badPinRefused(app) else { return }
        failOnSavePassword(app)

        // Leave without a retry: the member's password stays as it was.
        tap(app.buttons["top_bar_back"].firstMatch)
        if !waitUntil(timeout: 30, { !currentField.exists }) { return fail(app, "The password change did not close.") }
        lock(app)
    }

    /// I2.1 on staging (VAULT-MESSAGING §6.4): Connections → add → "Paste a link" with another member's invitation
    /// (`VETTID_STAGING_LINK`), "Connect", and the compare screen; its safety code is reported (an attachment named
    /// `safety-code` and a `SAFETY_CODE:` line) for the other member to compare. Nothing is approved; the vault is locked.
    @MainActor
    func testStagingConnectAccept() throws {
        try connectAccept()
    }

    /// The other side of ``testStagingConnectAccept``: Connections → the request card, its safety code checked against
    /// `VETTID_STAGING_SAFETY_CODE` when given (a different code fails, sending nothing), "Approve", and the outcome
    /// reported on a `CONNECT_STATE:` line. Then the vault is locked.
    @MainActor
    func testStagingConnectApprove() throws {
        try connectApprove()
    }

    // MARK: - Steps

    /// The open app, from whatever it shows at the start (unlocked with the PIN, and the password when the owner check is
    /// due); false, after the failure, when there is no vault.
    @MainActor
    func openAtStart(_ app: XCUIApplication, pin: String, password: String) -> Bool {
        switch waitForAny(app, ["unlock", "app_shell", "owner_check", "welcome_recover"], timeout: 60) {
        case "app_shell": break
        case "owner_check": ownerCheck(app, pin: pin, password: password)
        case "unlock": unlock(app, pin: pin, password: password)
        case let other:
            fail(app, "No vault on this phone: \(other ?? "no known screen") is shown.")
            return false
        }
        expect(app, "app_shell", timeout: Self.network)
        return true
    }

    /// The voluntary check's answer: true when its screen closed (after the presence notice, if any) on two snapshots in
    /// a row, the Settings [row] can be tapped again, and no failure showed meanwhile, a late one included; false after
    /// the failure. (A snapshot that fails reads as empty: it never counts as closed.)
    @MainActor
    private func checkPassed(_ app: XCUIApplication, row: XCUIElement) -> Bool {
        var screen: [String: String] = [:]
        var closedOnce = false
        let answered = waitUntil(timeout: Self.network) {
            screen = shown(app)
            if screen.isEmpty { return false }
            if screen["owner_check_passed_unrecorded"] != nil || failureText(in: screen) != nil { return true }
            let closed = screen["owner_check"] == nil
            defer { closedOnce = closed }
            return closed && closedOnce
        }
        if screen["owner_check_passed_unrecorded"] != nil {
            tapPrimary(app)
            if !waitUntil(timeout: 30, { let s = shown(app); return !s.isEmpty && s["owner_check_passed_unrecorded"] == nil }) {
                fail(app, "The check's presence notice did not close.")
                return false
            }
        } else if !answered || screen["owner_check"] != nil {
            let left = screen["owner_check_left"].map { " \($0)" } ?? ""
            fail(app, "The check did not pass: its screen is still open.\(left)")
            return false
        }
        // Back on Settings, under no check screen; a refusal that comes late still fails.
        if !waitUntil(timeout: 30, { row.exists && row.isHittable }) {
            fail(app, "Settings did not come back after the check.")
            return false
        }
        _ = waitUntil(timeout: 3) { failureText(in: shown(app)) != nil }
        if let why = failureText(in: shown(app)) {
            fail(app, "The check failed: \(why)")
            return false
        }
        return true
    }

    /// Settings → Credential → Change password; its current-password field, or nil after the failure.
    @MainActor
    private func openPasswordChange(_ app: XCUIApplication) -> XCUIElement? {
        openSettings(app)
        let credentialRow = app.buttons["credential_row"]
        guard reveal(app, credentialRow) else {
            fail(app, "Settings has no Credential row.")
            return nil
        }
        credentialRow.tap()
        expect(app, "credential", timeout: 30)
        let changeRow = app.buttons["change_password"]
        guard reveal(app, changeRow) else {
            fail(app, "The Credential screen has no \"Change password\".")
            return nil
        }
        changeRow.tap()
        let currentField = app.secureTextFields["change_password_current"]
        guard currentField.waitForExistence(timeout: 30) else {
            fail(app, "The password change did not open.")
            return nil
        }
        return currentField
    }

    /// The vault's answer to a password change with a wrong PIN: its refusal on the form ("error", "That PIN is not
    /// correct."), never a change; false after the failure.
    @MainActor
    private func badPinRefused(_ app: XCUIApplication) -> Bool {
        var screen: [String: String] = [:]
        _ = waitUntil(timeout: Self.network) {
            screen = shown(app)
            return ["error", "change_password_done", "change_check"].contains { screen[$0] != nil }
        }
        let why: String
        if screen["change_password_done"] != nil {
            why = "The vault changed the password with a wrong PIN: it is now the input password followed by "
                + "\"\(Self.wrongPinSuffix)\". Update VETTID_STAGING_PASSWORD in the inputs file to match."
        } else if let check = screen["change_check"] {
            why = "The change got no plain answer: \(check)"
        } else if let refusal = screen["error"] {
            if refusal.contains(Self.badPinText) { return true }
            why = "Not the wrong PIN's refusal: \(refusal)"
        } else {
            why = "The vault's refusal did not appear."
        }
        fail(app, why)
        return false
    }

    /// Scrolls the screen until [element] can be tapped; false when it never can.
    @MainActor
    func reveal(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        if !element.waitForExistence(timeout: Self.network) { return false }
        for _ in 0..<6 where !element.isHittable {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        return element.isHittable
    }

    /// The unlock screen ready for a PIN, from whatever the app shows at the start (the open app is locked first); false,
    /// after the failure, when there is no vault.
    @MainActor
    private func lockedAtStart(_ app: XCUIApplication, pin: String, password: String) -> Bool {
        switch waitForAny(app, ["unlock", "app_shell", "owner_check", "welcome_recover"], timeout: 60) {
        case "app_shell": lock(app)
        case "owner_check":
            ownerCheck(app, pin: pin, password: password)
            lock(app)
        case "unlock": break
        case let other:
            fail(app, "No vault on this phone: \(other ?? "no known screen") is shown.")
            return false
        }
        expect(app, "unlock", timeout: Self.network)
        let key = app.buttons["pin_1"]
        if !waitUntil(timeout: Self.network, { key.exists && key.isEnabled }) {
            fail(app, "The unlock screen never accepted a PIN.")
            return false
        }
        return true
    }

    /// The password when the owner check is due (VAULT-MESSAGING §3.6.5), the PIN, and "Unlock".
    @MainActor
    private func enterUnlock(_ app: XCUIApplication, pin: String, password: String) {
        let passwordField = app.secureTextFields["unlock_password"]
        if passwordField.exists {
            passwordField.tap()
            passwordField.typeText(password)
        }
        enterPin(app, pin)
        tapPrimary(app)
    }

    /// Settings, from the drawer. (An app left open on Settings has no menu button there: Settings has a back arrow.)
    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        if app.buttons["top_bar_menu"].waitForExistence(timeout: 10) {
            tap(app.buttons["top_bar_menu"])
            tap(app.buttons["drawer_settings"])
        }
    }

    @MainActor
    private func unlock(_ app: XCUIApplication, pin: String, password: String) {
        expect(app, "unlock", timeout: Self.network)
        // The keypad is enabled once the vault's software is checked (the preflight).
        let key = app.buttons["pin_1"]
        if !waitUntil(timeout: Self.network, { key.exists && key.isEnabled }) {
            return fail(app, "The unlock screen never accepted a PIN.")
        }
        // The owner check is due: the password goes with the PIN (VAULT-MESSAGING §3.6.5).
        let passwordField = app.secureTextFields["unlock_password"]
        if passwordField.exists {
            passwordField.tap()
            passwordField.typeText(password)
        }
        enterPin(app, pin)
        tapPrimary(app)
        switch waitForAny(app, ["app_shell", "owner_check"], timeout: Self.network) {
        case "owner_check":
            ownerCheck(app, pin: pin, password: password)
        case "app_shell":
            failOnSavePassword(app)
        default:
            fail(app, "The vault did not open.")
        }
    }

    /// The daily owner check past its deadline (VAULT-MESSAGING §3.6.5): the PIN and the password together.
    @MainActor
    private func ownerCheck(_ app: XCUIApplication, pin: String, password: String) {
        expect(app, "owner_check_pin", timeout: 30)
        enterPin(app, pin)
        let field = app.secureTextFields["owner_check_password"]
        field.tap()
        field.typeText(password)
        tapPrimary(app)
        if waitForAny(app, ["app_shell", "owner_check_passed_unrecorded"], timeout: Self.network) == "owner_check_passed_unrecorded" {
            tapPrimary(app)
        }
        expect(app, "app_shell", timeout: Self.network)
        failOnSavePassword(app)
    }

    /// "Lock vault" from the account sheet, then the unlock screen once the vault has confirmed the lock.
    @MainActor
    func lock(_ app: XCUIApplication) {
        expect(app, "app_shell", timeout: Self.network)
        // From Settings or a screen pushed over it: back arrows up to the screen with the account button.
        let account = app.buttons["top_bar_account"]
        for _ in 0..<4 where !(account.waitForExistence(timeout: 2) && account.isHittable) {
            let back = app.buttons["top_bar_back"].firstMatch
            guard back.exists, back.isHittable else { break }
            back.tap()
        }
        tap(account)
        tap(app.buttons["account_lock_vault"])
        expect(app, "unlock", timeout: Self.network)
        // "Locking…" until the vault confirms; only a confirmed lock passes (a vault left open keeps its host running,
        // STAGING-TESTING §5).
        if !waitUntil(timeout: Self.network, { shown(app)["unlock_lock_locking"] == nil }) {
            return fail(app, "The lock was not confirmed within \(Int(Self.network)) s: the screen still says it is locking.")
        }
        if let why = failureText(in: shown(app)) { fail(app, "The lock was not confirmed: \(why)") }
    }
}
