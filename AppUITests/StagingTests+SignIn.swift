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
        // Informational only: the bell's count is read from its label (the badge itself is hidden from accessibility).
        let bell = app.buttons["top_bar_bell"]
        print("SIGNIN_INDICATOR: \(bell.waitForExistence(timeout: 10) && bell.label.contains { $0.isNumber } ? "shown" : "none")")

        var state = "missing"
        // Every path reaches the lock at the end (STAGING-TESTING §5): no early return once unlocked.
        let opened = openFromDrawer(app, item: "drawer_approvals", screen: "approvals_screen", what: "Approvals")
        var row = opened ? signInRow(app, matchCode: matchCode, timeout: wait) : nil
        if cycle, let before = row {
            lock(app)
            unlock(app, pin: pin, password: password)
            var after: String?
            if openFromDrawer(app, item: "drawer_approvals", screen: "approvals_screen", what: "Approvals") {
                after = signInRow(app, matchCode: matchCode, timeout: wait)
            }
            print("SIGNIN_AFTER_LOCK: \(after == before ? "listed" : "missing")")
            if after != before { fail(app, "The same sign-in request was not listed after the lock and the unlock.") }
            row = after
        } else if cycle {
            print("SIGNIN_AFTER_LOCK: missing")
        }
        if let row { state = decide(app, row: row, matchCode: matchCode, password: password) }
        print("SIGNIN_STATE: \(state)")
        lock(app)
        if state != "approved" { fail(app, "The sign-in was not approved: \(state).") }
    }

    /// The identifier of the undecided "Sign in to …" row whose summary (the context's first line) holds the match
    /// code, waiting for it to be listed. Batches of asks are expanded and their rows read; the batch itself is skipped.
    @MainActor
    private func signInRow(_ app: XCUIApplication, matchCode: String, timeout: TimeInterval) -> String? {
        var found: String?
        var expanded = false
        _ = waitUntil(timeout: timeout) {
            guard let root = try? app.snapshot() else { return false }
            let all = ordered(under: root)
            if !expanded, let toggle = all.first(where: { $0.identifier.hasPrefix("approval_batch_toggle_") }) {
                expanded = true
                anyElement(app, toggle.identifier).tap()
                return false
            }
            found = all.first { e in
                e.identifier.hasPrefix("approval_") && !e.identifier.hasPrefix("approval_batch_toggle_")
                    && Self.plain(e.label).hasPrefix("Sign in to ") && Self.hasMatchCode(Self.plain(e.label), matchCode)
            }?.identifier
            return found != nil
        }
        return found
    }

    /// "match code NN" with exactly that number (the context reads "… match code NN").
    static func hasMatchCode(_ text: String, _ code: String) -> Bool {
        text.range(of: "match code \(NSRegularExpression.escapedPattern(for: code))(?!\\d)", options: .regularExpression) != nil
    }

    /// The request opened, its screen checked and approved; `approved`, `not_approved`, `not_opened` or `wrong_screen`.
    @MainActor
    private func decide(_ app: XCUIApplication, row: String, matchCode: String, password: String) -> String {
        tap(anyElement(app, row))
        guard waitForAny(app, ["approval_detail"], timeout: 30) != nil else { return "not_opened" }
        // The title is its own text ("Sign in to <name>?"); the context also begins "Sign in to", and ends otherwise.
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sign in to ' AND label ENDSWITH '?'"))
            .firstMatch
        let warning = app.staticTexts["Only approve if you are signing in right now."]
        let context = shown(app)["auth_context"].map(Self.plain) ?? ""
        let hasTitle = title.waitForExistence(timeout: 10)
        let hasWarning = warning.exists
        let hasCode = Self.hasMatchCode(context, matchCode)
        XCTAssertTrue(hasTitle, "The screen has no \"Sign in to <name>?\" title.")
        XCTAssertTrue(hasWarning, "The screen lacks its warning line.")
        XCTAssertTrue(hasCode, "The context does not show the match code.")
        guard hasTitle && hasWarning && hasCode else {
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
