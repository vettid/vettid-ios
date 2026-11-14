import XCTest

/// No AutoFill on the secret fields (IOS-PLAN §6.5): each secret field of the debug catalog's screens is focused, and
/// neither the keyboard's "Passwords" button nor its AutoFill key (`kb-autofill-key`) may show. Run with the
/// `VettIDScreenshots` scheme on an iPhone set to English that holds a saved password the app's domain could match (the
/// test iPhone 16e); skipped on a simulator. A control, an ordinary password field, must show the offer: on a phone
/// without a saved password, in another language, or once iOS renames these elements, the test fails there instead of
/// passing without proving anything. Before the secret fields took the one-time-code content type (vettid-ios #248),
/// both elements showed on the secure password fields of that iPhone.
final class AutofillUITests: XCTestCase {
    /// The catalog's start, the row's id, and the fields to focus (by accessibility id).
    struct Screen {
        let start: String
        let row: String
        let fields: [String]
    }

    static let screens = [
        // The setup email is not secret, but it is the username-like field next to the setup code.
        Screen(start: "onboarding", row: "catalog_onboarding_type", fields: ["setup_email", "setup_code"]),
        Screen(start: "onboarding", row: "catalog_onboarding_password", fields: ["password", "password_confirm"]),
        Screen(
            start: "shell", row: "catalog_shell_password",
            fields: ["change_password_current", "change_password_new", "change_password_confirm"]
        ),
        Screen(
            start: "shell", row: "catalog_shell_new_credential",
            fields: ["new_credential_current", "new_credential_new", "new_credential_confirm"]
        ),
        // The entry whose password is still empty (iOS offers nothing on a filled field).
        Screen(start: "shell", row: "catalog_shell_delete_phrase_wrong", fields: ["delete_password"]),
        Screen(start: "secrets", row: "catalog_secrets_recover_type", fields: ["recover_typed"]),
        Screen(start: "secrets", row: "catalog_secrets_transfer_paste", fields: ["transfer_code"]),
        Screen(start: "secrets", row: "catalog_secrets_recovery_open", fields: ["open_password"]),
        // Website, Username (right above the password), Password, one-time code.
        Screen(
            start: "secrets", row: "catalog_secrets_item_login",
            fields: ["item_edit_field_value_0", "item_edit_field_value_1", "item_edit_field_value_2", "item_edit_field_value_3"]
        ),
    ]

    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("AutoFill is checked on an iPhone that holds a saved password")
        #endif
        continueAfterFailure = true
    }

    @MainActor
    func testNoAutofillOnTheSecretFields() {
        // The control first: the check itself works on this phone.
        let control = launch("secrets", "catalog_secrets_control")
        if focus(control, "control_password") != nil {
            XCTAssertTrue(offered(control, within: 5), "the control shows no AutoFill: the phone has no saved password, is not "
                + "in English, or iOS renamed the elements; nothing below would be proven")
        }
        control.terminate()

        for screen in Self.screens {
            let app = launch(screen.start, screen.row)
            for id in screen.fields {
                guard focus(app, id) != nil else { continue }
                if offered(app, within: 3) {
                    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    shot.name = "autofill-\(id)"
                    shot.lifetime = .keepAlways
                    add(shot)
                    XCTFail("\(screen.row): \(id) offers AutoFill (IOS-PLAN §6.5)")
                }
            }
            app.terminate()
        }
    }

    /// The Debug app on the catalog row [row] of [start].
    @MainActor
    private func launch(_ start: String, _ row: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-vettid.start", start]
        app.launch()
        let b = app.buttons[row].firstMatch
        for _ in 0..<30 where !(b.exists && b.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(b.exists, "\(row) not in the catalog")
        // Tapped once the list has settled, and again if the first tap landed while it still moved.
        for _ in 0..<2 where b.exists && b.isHittable {
            sleep(1)
            b.tap()
            for _ in 0..<20 where b.isHittable { usleep(250_000) }
        }
        XCTAssertFalse(b.isHittable, "\(row) did not open")
        return app
    }

    /// The text input named [id] (or the one inside the element of that id), tapped until it has the keyboard's focus.
    @MainActor
    private func focus(_ app: XCUIApplication, _ id: String) -> XCUIElement? {
        let named = app.descendants(matching: .any)[id].firstMatch
        guard named.waitForExistence(timeout: 10) else {
            XCTFail("\(id) not found")
            return nil
        }
        let input = [app.secureTextFields[id], app.textFields[id], app.textViews[id],
                     named.descendants(matching: .secureTextField).firstMatch,
                     named.descendants(matching: .textField).firstMatch,
                     named.descendants(matching: .textView).firstMatch].first { $0.exists } ?? named
        for _ in 0..<2 where !hasFocus(input) {
            input.tap()
            for _ in 0..<10 where !hasFocus(input) { usleep(200_000) }
        }
        XCTAssertTrue(hasFocus(input), "\(id) did not take the keyboard's focus")
        return hasFocus(input) ? input : nil
    }

    private func hasFocus(_ e: XCUIElement) -> Bool { (e.value(forKey: "hasKeyboardFocus") as? Bool) == true }

    /// Whether the keyboard's "Passwords" button or AutoFill key shows at any moment within [seconds].
    @MainActor
    private func offered(_ app: XCUIApplication, within seconds: Double) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if app.buttons["Passwords"].exists || app.descendants(matching: .any)["kb-autofill-key"].exists { return true }
            usleep(250_000)
        } while Date() < end
        return false
    }
}
