import XCTest

/// No AutoFill on the secret fields (IOS-PLAN §6.5): each secret field of the debug catalog's screens is focused, and
/// neither the keyboard's "Passwords" button nor its AutoFill key may show. Run with the `VettIDScreenshots` scheme on an
/// iPhone that holds a saved password the app's domain could match (the test iPhone 16e); on a phone or simulator without
/// one it passes without proving much. Before the secret fields took the one-time-code content type (vettid-ios #248),
/// both elements showed on every secure password field of that iPhone.
final class AutofillUITests: XCTestCase {
    /// The catalog's start, the row's id, and the fields to focus (by accessibility id).
    struct Screen {
        let start: String
        let row: String
        let fields: [String]
    }

    static let screens = [
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
        Screen(start: "shell", row: "catalog_shell_delete", fields: ["delete_password"]),
    ]

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testNoAutofillOnTheSecretFields() {
        for screen in Self.screens {
            let app = XCUIApplication()
            app.launchArguments = ["-vettid.start", screen.start]
            app.launch()
            guard open(app, screen.row) else {
                XCTFail("\(screen.row) did not open")
                continue
            }
            for id in screen.fields {
                let field = app.descendants(matching: .any)[id].firstMatch
                guard field.waitForExistence(timeout: 10) else {
                    XCTFail("\(screen.row): \(id) not found")
                    continue
                }
                field.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "\(id): no keyboard")
                sleep(2)
                let offered = app.buttons["Passwords"].exists || app.descendants(matching: .any)["kb-autofill-key"].exists
                if offered {
                    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    shot.name = "autofill-\(id)"
                    shot.lifetime = .keepAlways
                    add(shot)
                }
                XCTAssertFalse(offered, "\(screen.row): \(id) offers AutoFill (IOS-PLAN §6.5)")
            }
            app.terminate()
        }
    }

    /// The catalog row tapped once the list has settled, and again if the first tap landed while it still moved.
    @MainActor
    private func open(_ app: XCUIApplication, _ row: String) -> Bool {
        let b = app.buttons[row].firstMatch
        for _ in 0..<30 where !(b.exists && b.isHittable) { app.swipeUp(velocity: .slow) }
        guard b.exists else { return false }
        for _ in 0..<2 {
            sleep(1)
            b.tap()
            for _ in 0..<20 where b.isHittable { usleep(250_000) }
            if !b.isHittable { return true }
        }
        return false
    }
}
