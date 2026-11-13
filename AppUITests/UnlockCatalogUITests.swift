import XCTest

/// The unlock screen's way back as VoiceOver and XCUITest read it, on the debug catalog's sample states (the Debug
/// app, `VettIDScreenshots` scheme): the link alone; the link with the refusal kept in the move's notice; the
/// check-first text with no link while the owner check gates the way back.
final class UnlockCatalogUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheWayBackInTheMovesNotice() {
        let offered = open("return_offered")
        XCTAssertTrue(offered.descendants(matching: .any)["unlock_move_unconfirmed"].exists)
        XCTAssertTrue(offered.buttons["Return to release 3"].exists, "the link")
        XCTAssertFalse(offered.descendants(matching: .any)["unlock_return_refused"].exists)
        XCTAssertFalse(offered.descendants(matching: .any)["unlock_return_check_first"].exists)

        let refused = open("return_refused")
        XCTAssertTrue(refused.descendants(matching: .any)["unlock_return_refused"].exists, "the refusal, in the move's notice")
        XCTAssertTrue(refused.buttons["Return to release 3"].exists, "the link stays")

        let gated = open("return_check_first")
        XCTAssertTrue(gated.descendants(matching: .any)["unlock_return_check_first"].exists, "the check-first text")
        XCTAssertFalse(gated.buttons["Return to release 3"].exists, "no link while gated")
        XCTAssertFalse(gated.descendants(matching: .any)["unlock_return_refused"].exists)
    }

    /// The Debug app on the unlock catalog's entry [id].
    @MainActor
    private func open(_ id: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-vettid.start", "unlock"]
        app.launch()
        let row = app.buttons["catalog_unlock_\(id)"]
        for _ in 0..<30 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["unlock_move_unconfirmed"].waitForExistence(timeout: 10), id)
        return app
    }
}
