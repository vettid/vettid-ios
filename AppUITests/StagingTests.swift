import XCTest

/// Staging end to end on a real iPhone (STAGING-TESTING §3 "Enrolling a phone", §5), the counterpart of vettid-android's
/// automated staging tests. Run with the `VettIDStagingUITests` scheme (the Staging build) through
/// `scripts/staging-ui-test.sh`, which hands the inputs to the test runner at run time:
///
/// - `VETTID_STAGING_EMAIL`: the test member's address;
/// - `VETTID_STAGING_CODE`: the 8-character code from the account site's "Enroll a phone" (it lives 5 minutes);
/// - `VETTID_STAGING_PIN`: the vault PIN;
/// - `VETTID_STAGING_PASSWORD`: the credential password.
///
/// A test whose inputs are missing is skipped, so CI and every other run never execute it. The inputs are never printed
/// and no failure message carries them (XCTest's own activity log names what is typed and tapped: the script redacts its
/// output and keeps the result bundle private).
final class StagingTests: XCTestCase {
    /// Network steps: a redeem, an unlock, a lock.
    private static let network: TimeInterval = 90
    /// Enrollment: the vault's enclave is made and attested, then the credential.
    private static let enrollment: TimeInterval = 600
    /// A release update: the lock, the unlock with the approval, and the unlock on the new release, which may have to
    /// start first (VAULT-MESSAGING §11.10.5: `503 release_starting`, minutes).
    private static let releaseUpdate: TimeInterval = 900

    /// Identifiers of the notices that say why something failed: their text is what a failure reports.
    private static let failureIds = [
        "error", "scan_refused", "pin_error", "pin_confirm_error", "credential_pin_error", "unlock_failed", "unlock_refused",
        "unlock_preflight_error", "unlock_pin_error", "unlock_not_recognised", "unlock_stuck", "unlock_recover_only",
        "unlock_signer_refused", "unlock_owner_check_locked", "unlock_lock_unconfirmed", "move_back_failed",
        "owner_check_failed", "owner_check_pin_error",
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

    // MARK: - Steps

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
    private func lock(_ app: XCUIApplication) {
        expect(app, "app_shell", timeout: Self.network)
        tap(app.buttons["top_bar_account"])
        tap(app.buttons["account_lock_vault"])
        expect(app, "unlock", timeout: Self.network)
        // "Locking…" until the vault confirms; only a confirmed lock passes (a vault left open keeps its host running,
        // STAGING-TESTING §5).
        if !waitUntil(timeout: Self.network, { shown(app)["unlock_lock_locking"] == nil }) {
            return fail(app, "The lock was not confirmed within \(Int(Self.network)) s: the screen still says it is locking.")
        }
        if let why = failureText(in: shown(app)) { fail(app, "The lock was not confirmed: \(why)") }
    }

    // MARK: - Helpers

    @MainActor
    private func launch() -> XCUIApplication {
        // A system alert met while the test acts on the app (the camera) is answered so that the run goes on; a "Save
        // Password?" is dismissed and remembered, and fails the test (``failOnSavePassword``).
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            Self.answer(alert)
        }
        let app = XCUIApplication()
        app.launch()
        return app
    }

    /// The camera prompt comes from SpringBoard as the scan screen opens; it is answered "Allow", so that the QR code can
    /// still be scanned by hand later.
    @MainActor
    private func allowSystemAlert() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 5) { _ = Self.answer(alert) }
    }

    /// A "Save Password?" prompt was met (IOS-PLAN §6.5: there must never be one).
    @MainActor private static var savePasswordSeen = false

    @MainActor
    private static func answer(_ alert: XCUIElement) -> Bool {
        if alert.buttons["Save Password"].exists || alert.label.localizedCaseInsensitiveContains("password") {
            savePasswordSeen = true
            if alert.buttons["Not Now"].exists { alert.buttons["Not Now"].tap() }
            return true
        }
        for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return true
        }
        return false
    }

    /// Fails, with a screenshot of the whole screen, when a "Save Password?" prompt showed or shows (IOS-PLAN §6.5).
    @MainActor
    private func failOnSavePassword(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let shows = app.buttons["Save Password"].exists || springboard.buttons["Save Password"].exists
        guard shows || Self.savePasswordSeen else { return }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "save-password"
        shot.lifetime = .keepAlways
        add(shot)
        XCTFail("iOS offered to save a password (IOS-PLAN §6.5 forbids it).")
    }

    @MainActor
    private func enterPin(_ app: XCUIApplication, _ pin: String) {
        for digit in pin {
            let key = app.buttons["pin_\(digit)"]
            XCTAssertTrue(key.waitForExistence(timeout: 10), "no keypad")
            key.tap()
        }
    }

    @MainActor
    private func tapPrimary(_ app: XCUIApplication) {
        let button = app.buttons["form_primary"]
        if !waitUntil(timeout: 30, { button.exists && button.isEnabled && button.isHittable }) {
            return fail(app, "The screen's button stayed disabled.")
        }
        button.tap()
    }

    @MainActor
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 30), "\(element.identifier) not found")
        element.tap()
    }

    /// Waits for the element [id]; fails at once with the app's own text when a failure notice appears instead.
    @MainActor
    private func expect(_ app: XCUIApplication, _ id: String, timeout: TimeInterval) {
        if waitForAny(app, [id], timeout: timeout) != id { fail(app, "\(id) did not appear.") }
    }

    /// The first of [ids] that appears, or nil after [timeout] or as soon as a failure notice shows.
    @MainActor
    private func waitForAny(_ app: XCUIApplication, _ ids: [String], timeout: TimeInterval) -> String? {
        var found: String?
        _ = waitUntil(timeout: timeout) {
            let screen = shown(app)
            found = ids.first { screen[$0] != nil }
            return found != nil || failureText(in: screen) != nil
        }
        return found
    }

    /// Polls [condition] every half second until it holds or [timeout] passes.
    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return true
    }

    /// The identifiers on screen with their labels, from one snapshot of the app (one query, not one per identifier).
    @MainActor
    private func shown(_ app: XCUIApplication) -> [String: String] {
        guard let root = try? app.snapshot() else { return [:] }
        var found: [String: String] = [:]
        var stack: [any XCUIElementSnapshot] = [root]
        while let e = stack.popLast() {
            if !e.identifier.isEmpty, found[e.identifier] == nil { found[e.identifier] = e.label }
            stack.append(contentsOf: e.children)
        }
        return found
    }

    /// The text of the failure notices in [screen], if any.
    private func failureText(in screen: [String: String]) -> String? {
        let texts = Self.failureIds.compactMap { screen[$0] }.filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: " | ")
    }

    /// Fails with [what] and the app's visible failure text, with a screenshot attached. `continueAfterFailure` is false,
    /// so the test stops here.
    @MainActor
    private func fail(_ app: XCUIApplication, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "failure"
        shot.lifetime = .keepAlways
        add(shot)
        let why = failureText(in: shown(app)).map { " The app shows: \($0)" } ?? ""
        XCTFail(what + why, file: file, line: line)
    }

    /// An input from the runner's environment (xcodebuild hands `TEST_RUNNER_<NAME>` over as `<NAME>`); the test is
    /// skipped without it. Only the variable's name is ever reported.
    private static func input(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("\(name) is not set: staging tests run only through scripts/staging-ui-test.sh")
        }
        return value
    }

    private static func pin() throws -> String {
        let pin = try input("VETTID_STAGING_PIN")
        guard pin.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw InputError.pinNotDigits }
        return pin
    }

    private enum InputError: Error, CustomStringConvertible {
        case pinNotDigits

        var description: String { "VETTID_STAGING_PIN is not all digits" }
    }
}
