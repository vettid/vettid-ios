import XCTest

/// A member-site sign-in approved on the iPhone (VAULT-MESSAGING §10.4): the site started it (`scripts/staging-signin-test.sh`
/// does that and passes the match code), the vault holds the challenge, and this test finds it in Approvals, checks the
/// screen and approves it.
extension StagingTests {
    /// Unlock; the approvals indicator; Approvals; the "Sign in to <name>?" request whose screen shows
    /// `VETTID_STAGING_MATCH_CODE`, with "Only approve if you are signing in right now."; approved (with the password if
    /// asked). With `VETTID_STAGING_SIGNIN_LOCK=1` the vault is locked and unlocked first and the request must still be
    /// listed (`pending.list`, VAULT-MESSAGING 0.70.0 §10.4.2). Waits up to `VETTID_STAGING_WAIT` seconds (120) for the
    /// request. Prints `SIGNIN_INDICATOR: shown|none`, `SIGNIN_AFTER_LOCK: listed|missing` (with the lock step) and
    /// `SIGNIN_STATE: approved|not_approved|not_opened|wrong_screen|missing`. Then the vault is locked.
    @MainActor
    func testStagingSignIn() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let matchCode = try Self.input("VETTID_STAGING_MATCH_CODE")
        let cycle = ProcessInfo.processInfo.environment["VETTID_STAGING_SIGNIN_LOCK"] == "1"
        let wait = try Self.wait(120)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        print("SIGNIN_INDICATOR: \(approvalsIndicator(app, timeout: wait) ? "shown" : "none")")

        var state = "missing"
        if cycle {
            lock(app)
            unlock(app, pin: pin, password: password)
            let listed = openFromDrawer(app, item: "drawer_approvals", screen: "approvals_screen", what: "Approvals")
                && signInRow(app, matchCode: matchCode, timeout: wait) != nil
            print("SIGNIN_AFTER_LOCK: \(listed ? "listed" : "missing")")
            if !listed { fail(app, "The sign-in request was not listed after the lock and the unlock.") }
        }
        if openFromDrawer(app, item: "drawer_approvals", screen: "approvals_screen", what: "Approvals") {
            if let row = signInRow(app, matchCode: matchCode, timeout: wait) {
                state = decide(app, row: row, matchCode: matchCode, password: password)
            }
        }
        print("SIGNIN_STATE: \(state)")
        lock(app)
        if state != "approved" { fail(app, "The sign-in was not approved: \(state).") }
    }

    /// Whether the top bar's bell (the approvals and notices indicator) carries a count in its label, waiting for it.
    @MainActor
    private func approvalsIndicator(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let bell = app.buttons["top_bar_bell"]
        guard bell.waitForExistence(timeout: 10) else { return false }
        return waitUntil(timeout: timeout) { bell.label.contains { $0.isNumber } || shown(app)["bell_badge"] != nil }
    }

    /// The identifier of the row titled "Sign in to …" that has not been decided, waiting for it to be listed.
    @MainActor
    private func signInRow(_ app: XCUIApplication, matchCode: String, timeout: TimeInterval) -> String? {
        var found: String?
        _ = waitUntil(timeout: timeout) {
            guard let root = try? app.snapshot() else { return false }
            found = ordered(under: root).first { e in
                e.identifier.hasPrefix("approval_") && Self.plain(e.label).contains("Sign in to")
            }?.identifier
            return found != nil
        }
        return found
    }

    /// The request opened, its screen checked and approved; `approved`, `not_approved`, `not_opened` or `wrong_screen`.
    @MainActor
    private func decide(_ app: XCUIApplication, row: String, matchCode: String, password: String) -> String {
        tap(anyElement(app, row))
        guard waitForAny(app, ["approval_detail"], timeout: 30) != nil else { return "not_opened" }
        let texts: [String] = (try? app.snapshot()).map { root in
            ordered(under: root).map { Self.plain($0.label) } + ordered(under: root).map { Self.plain($0.value as? String ?? "") }
        } ?? []
        let screen = texts.joined(separator: "\n")
        let right = screen.contains("Sign in to") && screen.contains("Only approve if you are signing in right now.")
            && screen.contains(matchCode)
        XCTAssertTrue(screen.contains("Sign in to"), "The screen has no \"Sign in to <name>?\" title.")
        XCTAssertTrue(screen.contains("Only approve if you are signing in right now."), "The screen lacks its warning line.")
        XCTAssertTrue(screen.contains(matchCode), "The screen does not show the match code.")
        guard right else {
            tap(app.buttons["top_bar_back"].firstMatch)
            return "wrong_screen"
        }
        let field = app.secureTextFields["approval_password"]
        if field.waitForExistence(timeout: 3) {
            field.tap()
            field.typeText(password)
        }
        tapPrimary(app)
        let left = waitUntil(timeout: Self.network) { shown(app)["approval_detail"] == nil }
        let failure = shown(app)["failure"]
        failOnSavePassword(app)
        if !left { tap(app.buttons["top_bar_back"].firstMatch) }
        return left && failure == nil ? "approved" : "not_approved"
    }
}
