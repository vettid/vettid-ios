import XCTest

/// The helpers of ``StagingTests``: launching the app, the system alerts, the keypad and the buttons, waiting for the
/// app's identifiers, failing with the app's own failure text, and the inputs.
extension StagingTests {
    @MainActor
    func launch() -> XCUIApplication {
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
        for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
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
    /// Fails, sending nothing, unless the keypad then holds exactly as many digits as [pin]: a missed tap must never
    /// send a wrong PIN, which the vault counts as a failed check (VAULT-MESSAGING §3.6.1).
    @MainActor
    func enterPin(_ app: XCUIApplication, _ pin: String) {
        dismissKeyboard(app)
        for digit in pin {
            let key = app.buttons["pin_\(digit)"]
            XCTAssertTrue(waitUntil(timeout: 10, { key.exists }), "no keypad")
            scrollToHittable(app, key)
            XCTAssertTrue(waitUntil(timeout: 10, { key.isHittable }), "the keypad cannot be reached")
            key.tap()
        }
        let dots = app.descendants(matching: .any)["pin_dots"]
        if dots.exists, let entered = dots.value as? String, entered != String(pin.count) {
            return fail(app, "The keypad holds \(entered) digits, not \(pin.count); nothing was sent.")
        }
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

    /// An input from the runner's environment (xcodebuild hands `TEST_RUNNER_<NAME>` over as `<NAME>`); the test is
    /// skipped without it. Only the variable's name is ever reported.
    static func input(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("\(name) is not set: staging tests run only through scripts/staging-ui-test.sh")
        }
        return value
    }

    static func pin() throws -> String {
        let pin = try input("VETTID_STAGING_PIN")
        guard pin.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw InputError.pinNotDigits }
        return pin
    }

    enum InputError: Error, CustomStringConvertible {
        case pinNotDigits

        var description: String { "VETTID_STAGING_PIN is not all digits" }
    }
}
