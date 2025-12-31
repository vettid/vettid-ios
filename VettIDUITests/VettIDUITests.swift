import XCTest

/// Base class for VettID UI tests
class VettIDUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helper Methods

    /// Wait for an element to exist with timeout
    func waitForElement(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    /// Wait for element to be hittable (visible and enabled)
    func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    /// Tap element with retry
    func tapWithRetry(_ element: XCUIElement, retries: Int = 3) {
        for i in 0..<retries {
            if element.exists && element.isHittable {
                element.tap()
                return
            }
            if i < retries - 1 {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        XCTFail("Element not tappable after \(retries) retries: \(element)")
    }

    /// Clear and type text in a text field
    func clearAndType(_ element: XCUIElement, text: String) {
        element.tap()

        // Select all and delete
        if let stringValue = element.value as? String, !stringValue.isEmpty {
            element.tap()
            element.press(forDuration: 1.0)

            let selectAll = app.menuItems["Select All"]
            if selectAll.waitForExistence(timeout: 1) {
                selectAll.tap()
            }
            element.typeText(XCUIKeyboardKey.delete.rawValue)
        }

        element.typeText(text)
    }
}

// MARK: - Accessibility Identifiers

/// Centralized accessibility identifiers for UI testing
enum AccessibilityID {
    enum Welcome {
        static let logo = "welcome.logo"
        static let title = "welcome.title"
        static let scanQRButton = "welcome.scanQRButton"
        static let enterCodeButton = "welcome.enterCodeButton"
    }

    enum ManualEnrollment {
        static let codeTextField = "manualEnrollment.codeTextField"
        static let continueButton = "manualEnrollment.continueButton"
        static let title = "manualEnrollment.title"
    }

    enum Enrollment {
        static let progressIndicator = "enrollment.progressIndicator"
        static let errorMessage = "enrollment.errorMessage"
        static let retryButton = "enrollment.retryButton"
        static let cancelButton = "enrollment.cancelButton"
    }

    enum QRScanner {
        static let scannerView = "qrScanner.scannerView"
        static let cancelButton = "qrScanner.cancelButton"
    }
}
