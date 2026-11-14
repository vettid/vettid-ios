import XCTest

/// (ANDROID-PLAN 0.1.124 §4 "The owner check's progress"; IOS-PLAN §4.17) The owner check while the vault verifies and on
/// a pass, as VoiceOver and XCUITest read it, on the debug catalog's sample states (the Debug app, `VettIDScreenshots`
/// scheme): "Checking with your vault…" with no entries, no Check and no Cancel, and Lock vault enabled on a gated check;
/// the tick's "Check passed" with no actions.
final class OwnerCheckCatalogUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheChecksProgress() {
        let gated = open("checking", until: "owner_check_checking", screen: "owner_check")
        XCTAssertTrue(gated.staticTexts["Checking with your vault…"].exists)
        XCTAssertFalse(gated.secureTextFields.firstMatch.exists, "no password")
        XCTAssertFalse(gated.descendants(matching: .any)["owner_check_pin"].exists, "no keypad")
        XCTAssertFalse(gated.buttons["form_primary"].exists, "no Check")
        let lock = gated.buttons["form_secondary"]
        XCTAssertTrue(lock.exists && lock.isEnabled && lock.label == "Lock vault", "Lock vault, enabled")

        let voluntary = open("checking_voluntary", until: "owner_check_checking", screen: "owner_check")
        XCTAssertFalse(voluntary.buttons["form_primary"].exists, "no Check")
        XCTAssertFalse(voluntary.buttons["form_secondary"].exists, "no Cancel")
        XCTAssertFalse(voluntary.buttons["owner_check_cancel"].exists)

        // A failed Lock vault while the dropped check is out: its notice shows under the line, with Lock vault.
        let lockFailed = open("checking_lock_failed", until: "owner_check_checking", screen: "owner_check")
        XCTAssertTrue(lockFailed.descendants(matching: .any)["owner_check_failed"].exists, "the lock's failure is shown")
        XCTAssertTrue(lockFailed.buttons["form_secondary"].isEnabled, "Lock vault, again")
        XCTAssertFalse(lockFailed.buttons["form_primary"].exists, "no Check")

        let passed = open("passed", until: "owner_check_passed_text", screen: "owner_check_passed")
        XCTAssertTrue(passed.staticTexts["Check passed"].exists)
        XCTAssertFalse(passed.buttons["form_primary"].exists)
        XCTAssertFalse(passed.buttons["form_secondary"].exists)
    }

    /// The screen [screen] of the Debug app on the owner-check catalog's entry [id], once [element] shows (the catalog's
    /// list stays under it).
    @MainActor
    private func open(_ id: String, until element: String, screen: String) -> XCUIElement {
        let app = XCUIApplication()
        app.launchArguments = ["-vettid.start", "ownerCheck"]
        app.launch()
        let row = app.buttons["catalog_owner_check_\(id)"]
        for _ in 0..<30 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)[element].waitForExistence(timeout: 10), id)
        return app.descendants(matching: .any)[screen].firstMatch
    }
}
