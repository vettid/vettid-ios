import XCTest

/// Screenshots of the debug component gallery for review against the Android gallery (IOS-PLAN I0.2): the whole
/// gallery, page by page, in the dark and light themes and at the largest accessibility text size. Run with the
/// `VettIDScreenshots` scheme; the screenshots are kept as attachments of the result bundle.
final class GalleryScreenshots: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDark() { capture("dark", arguments: ["-vettid.theme", "dark"]) }

    @MainActor
    func testLight() { capture("light", arguments: ["-vettid.theme", "light"]) }

    @MainActor
    func testLargestText() {
        capture("ax-xxxl", arguments: [
            "-vettid.theme", "dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
    }

    @MainActor
    private func capture(_ name: String, arguments: [String]) {
        let app = XCUIApplication()
        app.launchArguments = ["-vettid.start", "gallery"] + arguments
        app.launch()
        let gallery = app.descendants(matching: .any)["component_gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 10))
        let scroll = app.scrollViews.firstMatch
        let end = app.buttons["Confirm dialog"]
        for page in 0..<40 {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = String(format: "%@-%02d", name, page)
            shot.lifetime = .keepAlways
            add(shot)
            if end.exists, end.isHittable { break }
            scroll.swipeUp(velocity: .slow)
        }
    }
}
