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

    enum Unlock {
        static let view = "unlockView"
        static let logo = "unlock.logo"
        static let title = "unlock.title"
        static let subtitle = "unlock.subtitle"
        static let biometricButton = "unlock.biometricButton"
        static let passwordButton = "unlock.passwordButton"
    }

    enum Auth {
        // Action Request View
        static let actionRequestView = "auth.actionRequestView"
        static let actionRequestIcon = "auth.actionRequest.icon"
        static let actionRequestTitle = "auth.actionRequest.title"
        static let actionRequestSubtitle = "auth.actionRequest.subtitle"
        static let keysAvailable = "auth.actionRequest.keysAvailable"
        static let noKeys = "auth.actionRequest.noKeys"
        static let beginButton = "auth.actionRequest.beginButton"

        // Requesting Token View
        static let requestingTokenView = "auth.requestingTokenView"
        static let requestingTokenSpinner = "auth.requestingToken.spinner"
        static let requestingTokenTitle = "auth.requestingToken.title"

        // LAT Verification View
        static let latVerificationView = "auth.latVerificationView"
        static let latVerificationIcon = "auth.latVerification.icon"
        static let latVerificationTitle = "auth.latVerification.title"
        static let serverLatLabel = "auth.latVerification.serverLatLabel"
        static let serverLatValue = "auth.latVerification.serverLatValue"
        static let latVerified = "auth.latVerification.verified"
        static let latMismatch = "auth.latVerification.mismatch"
        static let continueToPassword = "auth.latVerification.continueButton"
        static let phishingWarning = "auth.latVerification.phishingWarning"
        static let reportPhishing = "auth.latVerification.reportButton"

        // Password Entry View
        static let passwordView = "auth.passwordView"
        static let passwordIcon = "auth.password.icon"
        static let passwordTitle = "auth.password.title"
        static let passwordSubtitle = "auth.password.subtitle"
        static let passwordTextField = "auth.password.textField"
        static let submitButton = "auth.password.submitButton"

        // Authenticating View
        static let authenticatingView = "auth.authenticatingView"
        static let authenticatingSpinner = "auth.authenticating.spinner"
        static let authenticatingTitle = "auth.authenticating.title"

        // Success View
        static let successView = "auth.successView"
        static let successIcon = "auth.success.icon"
        static let successTitle = "auth.success.title"
        static let successSubtitle = "auth.success.subtitle"
        static let rotationInfo = "auth.success.rotationInfo"
        static let continueButton = "auth.success.continueButton"

        // Error View
        static let errorView = "auth.errorView"
        static let errorIcon = "auth.error.icon"
        static let errorTitle = "auth.error.title"
        static let errorMessage = "auth.error.message"
        static let retryButton = "auth.error.retryButton"
        static let cancelButton = "auth.error.cancelButton"
    }
}
