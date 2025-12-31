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

    enum VaultStatus {
        static let loadingView = "vault.loadingView"
        static let loadingSpinner = "vault.loading.spinner"
        static let loadingText = "vault.loading.text"

        static let notEnrolledView = "vault.notEnrolledView"
        static let notEnrolledIcon = "vault.notEnrolled.icon"
        static let notEnrolledTitle = "vault.notEnrolled.title"
        static let notEnrolledSubtitle = "vault.notEnrolled.subtitle"
        static let setupButton = "vault.notEnrolled.setupButton"

        static let statusCard = "vault.statusCard"
        static let statusIcon = "vault.status.icon"
        static let statusLabel = "vault.status.label"
        static let statusValue = "vault.status.value"

        static let actionsSection = "vault.actionsSection"
        static let startButton = "vault.actions.startButton"
        static let stopButton = "vault.actions.stopButton"
        static let syncButton = "vault.actions.syncButton"

        static let errorView = "vault.errorView"
        static let errorIcon = "vault.error.icon"
        static let errorTitle = "vault.error.title"
        static let errorMessage = "vault.error.message"
        static let retryButton = "vault.error.retryButton"
    }

    enum VaultHealth {
        static let loadingView = "vaultHealth.loadingView"
        static let loadingSpinner = "vaultHealth.loading.spinner"
        static let loadingText = "vaultHealth.loading.text"

        static let notProvisionedView = "vaultHealth.notProvisionedView"
        static let notProvisionedIcon = "vaultHealth.notProvisioned.icon"
        static let notProvisionedTitle = "vaultHealth.notProvisioned.title"
        static let notProvisionedSubtitle = "vaultHealth.notProvisioned.subtitle"
        static let provisionButton = "vaultHealth.notProvisioned.provisionButton"

        static let provisioningView = "vaultHealth.provisioningView"
        static let provisioningProgressCircle = "vaultHealth.provisioning.progressCircle"
        static let provisioningProgress = "vaultHealth.provisioning.progress"
        static let provisioningTitle = "vaultHealth.provisioning.title"
        static let provisioningStatus = "vaultHealth.provisioning.status"
        static let provisioningHint = "vaultHealth.provisioning.hint"

        static let stoppedView = "vaultHealth.stoppedView"
        static let stoppedIcon = "vaultHealth.stopped.icon"
        static let stoppedTitle = "vaultHealth.stopped.title"
        static let stoppedSubtitle = "vaultHealth.stopped.subtitle"
        static let startButton = "vaultHealth.stopped.startButton"

        static let errorView = "vaultHealth.errorView"
        static let errorIcon = "vaultHealth.error.icon"
        static let errorTitle = "vaultHealth.error.title"
        static let errorMessage = "vaultHealth.error.message"
        static let retryButton = "vaultHealth.error.retryButton"

        // Details View
        static let statusHeader = "vaultHealth.details.statusHeader"
        static let statusIndicator = "vaultHealth.details.statusIndicator"
        static let statusText = "vaultHealth.details.statusText"
        static let uptime = "vaultHealth.details.uptime"
        static let actionsSection = "vaultHealth.details.actionsSection"
        static let stopButton = "vaultHealth.details.stopButton"
        static let terminateButton = "vaultHealth.details.terminateButton"
        static let lastEvent = "vaultHealth.details.lastEvent"
    }

    enum VaultPreferences {
        static let list = "vaultPreferences.list"
        static let sessionTimeout = "vaultPreferences.sessionTimeout"
        static let changePasswordButton = "vaultPreferences.changePasswordButton"
        static let manageHandlersLink = "vaultPreferences.manageHandlersLink"
        static let archiveAfterDays = "vaultPreferences.archiveAfterDays"
        static let deleteAfterDays = "vaultPreferences.deleteAfterDays"
        static let viewArchiveLink = "vaultPreferences.viewArchiveLink"
        static let clearCacheButton = "vaultPreferences.clearCacheButton"
    }

    enum Archive {
        static let view = "archive.view"
        static let loading = "archive.loading"
        static let emptyView = "archive.emptyView"
        static let emptyIcon = "archive.empty.icon"
        static let emptyTitle = "archive.empty.title"
        static let emptySubtitle = "archive.empty.subtitle"
        static let selectButton = "archive.selectButton"
        static let deleteButton = "archive.deleteButton"
        static let list = "archive.list"
        static let filterSection = "archive.filterSection"
    }
}
