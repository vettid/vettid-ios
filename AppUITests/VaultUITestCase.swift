import XCTest

/// What the app's UI tests share (``StagingTests`` on a real iPhone, ``DevStackTests`` on the simulator): launching the
/// app, the system alerts, the keypad and the buttons, waiting for the app's identifiers, failing with the app's own
/// failure text, and the unlock, owner check and lock steps. It has no tests of its own.
class VaultUITestCase: XCTestCase {
    /// Network steps: a redeem, an unlock, a lock.
    class var network: TimeInterval { 90 }
    /// Enrollment: the vault's enclave is made and attested, then the credential.
    class var enrollment: TimeInterval { 600 }

    /// Identifiers of the notices that say why something failed: their text is what a failure reports.
    static let failureIds = [
        "error", "scan_refused", "pin_error", "pin_confirm_error", "credential_pin_error", "unlock_failed", "unlock_refused",
        "unlock_preflight_error", "unlock_pin_error", "unlock_not_recognised", "unlock_stuck", "unlock_recover_only",
        "unlock_signer_refused", "unlock_owner_check_locked", "unlock_lock_unconfirmed", "move_back_failed",
        "owner_check_failed", "owner_check_pin_error", "failure", "messages_error", "conversation_error",
    ]

    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { Self.savePasswordSeen = false }
    }

    /// [environment]: the app's launch environment (the dev stack's addresses).
    @MainActor
    func launch(environment: [String: String] = [:]) -> XCUIApplication {
        // A system alert met while the test acts on the app (the camera) is answered so that the run goes on; a "Save
        // Password?" is dismissed and remembered, and fails the test (``failOnSavePassword``).
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            Self.answer(alert)
        }
        let app = XCUIApplication()
        app.launchEnvironment.merge(environment) { $1 }
        app.launch()
        return app
    }

    /// The camera prompt comes from SpringBoard as the scan screen opens; it is answered "Allow", so that the QR code can
    /// still be scanned by hand later.
    @MainActor
    func allowSystemAlert() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 5) { _ = Self.answer(alert) }
    }

    /// A "Save Password?" prompt was met (IOS-PLAN §6.5: there must never be one).
    @MainActor static var savePasswordSeen = false

    @MainActor
    static func answer(_ alert: XCUIElement) -> Bool {
        if alert.buttons["Save Password"].exists || alert.label.localizedCaseInsensitiveContains("password") {
            savePasswordSeen = true
            if alert.buttons["Not Now"].exists { alert.buttons["Not Now"].tap() }
            return true
        }
        // The first match: an iOS permission alert can expose the same button twice ("Allow" found more than once).
        for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
            alert.buttons[label].firstMatch.tap()
            return true
        }
        return false
    }

    /// Fails, with a screenshot of the whole screen, when a "Save Password?" prompt showed or shows (IOS-PLAN §6.5).
    @MainActor
    func failOnSavePassword(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let shows = app.buttons["Save Password"].exists || springboard.buttons["Save Password"].exists
        guard shows || Self.savePasswordSeen else { return }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "save-password"
        shot.lifetime = .keepAlways
        add(shot)
        XCTFail("iOS offered to save a password (IOS-PLAN §6.5 forbids it).")
    }

    /// The PIN on the keypad, one digit at a time, each key tapped only once it can be hit (not under the keyboard).
    /// True only when the keypad then holds exactly as many digits as [pin]: a missed tap must never send a wrong PIN,
    /// which the vault counts as a failed check (VAULT-MESSAGING §3.6.1). On false the failure is recorded and the caller
    /// must send nothing (a test that goes on after a failure must check it).
    @MainActor @discardableResult
    func enterPin(_ app: XCUIApplication, _ pin: String) -> Bool {
        dismissKeyboard(app)
        for digit in pin {
            let key = app.buttons["pin_\(digit)"]
            guard waitUntil(timeout: 10, { key.exists }) else {
                fail(app, "The keypad is not there; nothing was sent.")
                return false
            }
            scrollToHittable(app, key)
            guard waitUntil(timeout: 10, { key.isHittable }) else {
                fail(app, "The keypad cannot be reached; nothing was sent.")
                return false
            }
            key.tap()
        }
        let dots = app.descendants(matching: .any)["pin_dots"]
        // Fails closed: a keypad whose digit count cannot be read is not trusted.
        guard dots.exists, let entered = dots.value as? String, entered == String(pin.count) else {
            let held = (dots.value as? String).map { "\($0) digits, not \(pin.count)" } ?? "an unreadable number of digits"
            fail(app, "The keypad holds \(held); nothing was sent.")
            return false
        }
        return true
    }

    /// Scrolls the screen up until [element] can be tapped (a long notice, such as the unlock screen's What's new, can
    /// push the keypad below the screen). Drags from the top of the screen, which is the screen's own scrolling content,
    /// not a card that scrolls on its own.
    @MainActor
    func scrollToHittable(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<8 where !element.isHittable {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        }
    }

    /// Puts the keyboard away (after typing a password) so it cannot cover the keypad.
    @MainActor
    func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }
        for name in ["Return", "return", "Done", "done", "Go", "go"] where app.keyboards.buttons[name].exists {
            app.keyboards.buttons[name].tap()
            break
        }
        _ = waitUntil(timeout: 3, { app.keyboards.count == 0 })
    }

    @MainActor
    func tapPrimary(_ app: XCUIApplication) {
        let button = app.buttons["form_primary"]
        if !waitUntil(timeout: 30, { button.exists && button.isEnabled && button.isHittable }) {
            return fail(app, "The screen's button stayed disabled.")
        }
        button.tap()
    }

    @MainActor
    func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 30), "\(element.identifier) not found")
        element.tap()
    }

    /// Waits for the element [id]; fails at once with the app's own text when a failure notice appears instead.
    @MainActor
    func expect(_ app: XCUIApplication, _ id: String, timeout: TimeInterval) {
        if waitForAny(app, [id], timeout: timeout) != id { fail(app, "\(id) did not appear.") }
    }

    /// The first of [ids] that appears, or nil after [timeout] or as soon as a failure notice shows.
    @MainActor
    func waitForAny(_ app: XCUIApplication, _ ids: [String], timeout: TimeInterval) -> String? {
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
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return true
    }

    /// The identifiers on screen with their labels, from one snapshot of the app (one query, not one per identifier).
    @MainActor
    func shown(_ app: XCUIApplication) -> [String: String] {
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
    func failureText(in screen: [String: String]) -> String? {
        let texts = Self.failureIds.compactMap { screen[$0] }.filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: " | ")
    }

    /// Fails with [what] and the app's visible failure text, with a screenshot attached. `continueAfterFailure` is false,
    /// so the test stops here.
    @MainActor
    func fail(_ app: XCUIApplication, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "failure"
        shot.lifetime = .keepAlways
        add(shot)
        let why = failureText(in: shown(app)).map { " The app shows: \($0)" } ?? ""
        XCTFail(what + why, file: file, line: line)
    }

    @MainActor
    func unlock(_ app: XCUIApplication, pin: String, password: String) {
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

    /// The daily owner check past its deadline (VAULT-MESSAGING §3.6.5): the PIN and the password together. False, after
    /// the failure, when the PIN was not entered whole (nothing is sent then).
    @MainActor @discardableResult
    func ownerCheck(_ app: XCUIApplication, pin: String, password: String) -> Bool {
        expect(app, "owner_check_pin", timeout: 30)
        guard enterPin(app, pin) else { return false }
        let field = app.secureTextFields["owner_check_password"]
        field.tap()
        field.typeText(password)
        tapPrimary(app)
        if waitForAny(app, ["app_shell", "owner_check_passed_unrecorded"], timeout: Self.network) == "owner_check_passed_unrecorded" {
            tapPrimary(app)
        }
        expect(app, "app_shell", timeout: Self.network)
        failOnSavePassword(app)
        return shown(app)["app_shell"] != nil
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

    /// STAGING-TESTING §3 from the welcome screen of a fresh app: "Scan", the typed code with the member's address, "Is
    /// this your account?", the PIN on the keypad and its confirmation, the credential password (with the PIN when the
    /// release asks for it), the default backup, the enrollment, and the open app.
    @MainActor
    func enroll(_ app: XCUIApplication, email: String, code: String, pin: String, password: String) {
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
}
