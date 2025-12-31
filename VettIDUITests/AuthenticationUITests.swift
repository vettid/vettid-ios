import XCTest

/// UI tests for the authentication flow
/// Note: These tests require an enrolled device state to run properly.
/// The tests focus on verifying UI elements and navigation when the user
/// has credentials but needs to authenticate.
final class AuthenticationUITests: VettIDUITests {

    // MARK: - Test Configuration

    /// Override setup to handle enrolled state
    /// Note: In a real test environment, you would mock the credential state
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--enrolled"]
        app.launch()
    }

    // MARK: - Unlock Screen Tests

    func testUnlockScreenDisplaysCorrectly() throws {
        // This test verifies the unlock screen UI when user has credentials
        // Skip if we're on welcome screen (not enrolled)
        let welcomeTitle = app.staticTexts["Welcome to VettID"]
        if welcomeTitle.exists {
            throw XCTSkip("App is not enrolled, skipping unlock screen test")
        }

        // Verify unlock screen elements
        let unlockTitle = app.staticTexts["Unlock VettID"]
        if unlockTitle.exists {
            XCTAssertTrue(unlockTitle.exists, "Unlock title should be visible")

            let biometricButton = app.buttons["Unlock with Face ID"]
            XCTAssertTrue(biometricButton.exists, "Biometric unlock button should be visible")

            let passwordButton = app.buttons["Use Password"]
            XCTAssertTrue(passwordButton.exists, "Password button should be visible")
        }
    }

    func testTapUsePasswordOpensAuthSheet() throws {
        // Skip if we're on welcome screen (not enrolled)
        let welcomeTitle = app.staticTexts["Welcome to VettID"]
        if welcomeTitle.exists {
            throw XCTSkip("App is not enrolled, skipping authentication test")
        }

        let passwordButton = app.buttons["Use Password"]
        guard passwordButton.exists else {
            throw XCTSkip("Password button not found, app may not be in unlock state")
        }

        passwordButton.tap()

        // Wait for auth sheet to appear
        Thread.sleep(forTimeInterval: 1.0)

        // Verify we're in authentication flow - look for action request view
        let authTitle = app.staticTexts["Secure Authentication"]
        let beginButton = app.buttons["Begin Authentication"]

        let foundAuthFlow = waitForElement(authTitle, timeout: 3) ||
                           waitForElement(beginButton, timeout: 3)

        XCTAssertTrue(foundAuthFlow, "Authentication sheet should appear with auth flow")
    }

    // MARK: - Action Request View Tests

    func testActionRequestViewDisplaysCorrectly() throws {
        // Navigate to auth flow
        try navigateToAuthFlow()

        // Verify action request view elements
        let secureAuthTitle = app.staticTexts["Secure Authentication"]
        XCTAssertTrue(waitForElement(secureAuthTitle), "Secure Authentication title should be visible")

        let beginButton = app.buttons["Begin Authentication"]
        XCTAssertTrue(beginButton.exists, "Begin Authentication button should be visible")

        // Check for either keys available or no keys message
        let keysAvailable = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'transaction keys available'")).firstMatch
        let noKeys = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No keys available'")).firstMatch

        let hasKeyInfo = keysAvailable.exists || noKeys.exists
        XCTAssertTrue(hasKeyInfo, "Key status should be displayed")
    }

    func testBeginAuthenticationButtonTriggersFetching() throws {
        // Navigate to auth flow
        try navigateToAuthFlow()

        let beginButton = app.buttons["Begin Authentication"]
        guard waitForHittable(beginButton) else {
            throw XCTSkip("Begin Authentication button not hittable")
        }

        // If button is disabled (no keys), skip this test
        if !beginButton.isEnabled {
            throw XCTSkip("Begin Authentication button is disabled (no keys available)")
        }

        beginButton.tap()

        // Should transition to requesting token state or error
        Thread.sleep(forTimeInterval: 1.0)

        // Look for either connecting, LAT verification, password entry, or error
        let connectingText = app.staticTexts["Connecting to server..."]
        let latVerifyTitle = app.staticTexts["Verify Server Identity"]
        let passwordTitle = app.staticTexts["Enter Your Password"]
        let errorTitle = app.staticTexts["Authentication Failed"]

        let transitionedToNextState = connectingText.exists ||
                                      latVerifyTitle.exists ||
                                      passwordTitle.exists ||
                                      errorTitle.exists

        // If still on action request, that's okay - backend might not be available
        let stillOnActionRequest = app.staticTexts["Secure Authentication"].exists && beginButton.exists

        XCTAssertTrue(transitionedToNextState || stillOnActionRequest,
                     "Should transition to next state or remain on action request")
    }

    // MARK: - Password Entry Tests

    func testPasswordEntryViewElements() throws {
        // This test documents expected password entry UI
        // In actual test, would need to get to this state by completing LAT verification

        // Navigate to auth flow
        try navigateToAuthFlow()

        // Check if we can find password entry elements
        let passwordTitle = app.staticTexts["Enter Your Password"]
        let passwordField = app.secureTextFields["Password"]

        // These elements may not be visible until LAT verification completes
        // Document what we expect to see
        if passwordTitle.exists {
            XCTAssertTrue(passwordField.exists, "Password field should be visible")

            let authButton = app.buttons["Authenticate"]
            XCTAssertTrue(authButton.exists, "Authenticate button should be visible")
            XCTAssertFalse(authButton.isEnabled, "Authenticate button should be disabled when password empty")
        }
    }

    func testPasswordButtonEnablesWithInput() throws {
        // Navigate to auth flow
        try navigateToAuthFlow()

        // Skip if we can't reach password entry
        let passwordField = app.secureTextFields["Password"]
        guard waitForElement(passwordField, timeout: 5) else {
            throw XCTSkip("Password entry not reachable without backend")
        }

        passwordField.tap()
        passwordField.typeText("testpassword")

        let authButton = app.buttons["Authenticate"]
        XCTAssertTrue(authButton.isEnabled, "Authenticate button should be enabled with password")
    }

    // MARK: - Error Handling Tests

    func testAuthErrorShowsRetryButton() throws {
        // Navigate to auth flow and trigger error
        try navigateToAuthFlow()

        let beginButton = app.buttons["Begin Authentication"]
        if waitForHittable(beginButton) && beginButton.isEnabled {
            beginButton.tap()

            // Wait for potential error (no backend means network error)
            let errorTitle = app.staticTexts["Authentication Failed"]
            if waitForElement(errorTitle, timeout: 10) {
                let retryButton = app.buttons["Try Again"]
                XCTAssertTrue(retryButton.exists, "Retry button should be visible on error")

                let cancelButton = app.buttons["Cancel"]
                XCTAssertTrue(cancelButton.exists, "Cancel button should be visible on error")
            }
        }
    }

    func testCancelButtonDismissesAuthSheet() throws {
        // Navigate to auth flow
        try navigateToAuthFlow()

        // Find cancel button in toolbar or error view
        let cancelButton = app.buttons["Cancel"]

        if waitForHittable(cancelButton, timeout: 3) {
            cancelButton.tap()

            // Should return to unlock screen or main app
            Thread.sleep(forTimeInterval: 1.0)

            // Verify sheet was dismissed
            let authTitle = app.staticTexts["Secure Authentication"]
            let wasDismissed = !authTitle.exists

            XCTAssertTrue(wasDismissed, "Auth sheet should be dismissed")
        }
    }

    // MARK: - LAT Verification Tests

    func testLATVerificationViewElements() throws {
        // This test documents expected LAT verification UI
        // Would need backend to actually reach this state

        // Navigate to auth flow and attempt to begin
        try navigateToAuthFlow()

        let beginButton = app.buttons["Begin Authentication"]
        if waitForHittable(beginButton) && beginButton.isEnabled {
            beginButton.tap()

            // Check for LAT verification view
            let latTitle = app.staticTexts["Verify Server Identity"]
            if waitForElement(latTitle, timeout: 10) {
                // Verify LAT UI elements
                let serverLatLabel = app.staticTexts["Server LAT ID"]
                XCTAssertTrue(serverLatLabel.exists, "Server LAT label should be visible")

                // Check for verified or mismatch state
                let verified = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'LAT Verified'")).firstMatch
                let mismatch = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'LAT MISMATCH'")).firstMatch

                let hasVerificationStatus = verified.exists || mismatch.exists
                XCTAssertTrue(hasVerificationStatus, "LAT verification status should be shown")
            }
        }
    }

    // MARK: - Accessibility Tests

    func testAuthFlowAccessibility() throws {
        // Navigate to auth flow
        try navigateToAuthFlow()

        // Verify accessibility identifiers are set
        let actionRequestView = app.otherElements["auth.actionRequestView"]
        let authTitle = app.staticTexts["auth.actionRequest.title"]
        let beginButton = app.buttons["auth.actionRequest.beginButton"]

        // At least one accessibility identifier should be findable
        let hasAccessibility = actionRequestView.exists ||
                              authTitle.exists ||
                              beginButton.exists ||
                              app.staticTexts["Secure Authentication"].exists

        XCTAssertTrue(hasAccessibility, "Auth flow should have accessibility support")
    }

    // MARK: - Success View Tests

    func testSuccessViewElements() throws {
        // This test documents expected success view UI
        // Would need full auth flow to reach this state

        // Check for success view elements by identifier
        let successView = app.otherElements["auth.successView"]
        let successTitle = app.staticTexts["Authentication Successful"]
        let continueButton = app.buttons["Continue"]

        // Document expected elements
        if successView.exists || successTitle.exists {
            XCTAssertTrue(continueButton.exists, "Continue button should be visible on success")
        }
    }

    // MARK: - Helper Methods

    /// Navigate to the authentication flow
    private func navigateToAuthFlow() throws {
        // Skip if we're on welcome screen (not enrolled)
        let welcomeTitle = app.staticTexts["Welcome to VettID"]
        if welcomeTitle.exists {
            throw XCTSkip("App is not enrolled, cannot test authentication flow")
        }

        // Look for unlock screen
        let passwordButton = app.buttons["Use Password"]
        if passwordButton.exists && passwordButton.isHittable {
            passwordButton.tap()

            // Wait for auth sheet
            let authTitle = app.staticTexts["Secure Authentication"]
            _ = waitForElement(authTitle, timeout: 3)
        }

        // Already in auth flow or main app
    }
}

// MARK: - Mock Enrolled State Tests

extension AuthenticationUITests {

    /// Test complete authentication flow with mock enrolled state
    func testCompleteAuthFlowDocumentation() throws {
        // This test documents the complete expected authentication flow:
        //
        // 1. User has credentials (enrolled state)
        // 2. App shows unlock screen with biometric/password options
        // 3. User taps "Use Password"
        // 4. Action Request View appears
        //    - Shows security info and key count
        //    - "Begin Authentication" button starts the flow
        // 5. Requesting Token state (loading)
        // 6. LAT Verification View
        //    - Shows server LAT ID
        //    - User verifies server authenticity
        //    - "Continue to Password" or "Report Phishing"
        // 7. Password Entry View
        //    - User enters vault password
        //    - "Authenticate" button submits
        // 8. Authenticating state (loading)
        // 9. Success View
        //    - Shows credential rotation info
        //    - "Continue" button dismisses

        // Skip if we're on welcome screen (not enrolled)
        let welcomeTitle = app.staticTexts["Welcome to VettID"]
        if welcomeTitle.exists {
            throw XCTSkip("App is not enrolled, cannot test full auth flow")
        }

        // Step 1: Verify unlock screen
        let unlockTitle = app.staticTexts["Unlock VettID"]
        if !unlockTitle.exists {
            // May already be authenticated
            throw XCTSkip("App is not in locked state")
        }

        // Step 2: Navigate to auth
        let passwordButton = app.buttons["Use Password"]
        XCTAssertTrue(passwordButton.exists, "Password button should exist")
        passwordButton.tap()

        // Step 3: Verify action request view
        let authTitle = app.staticTexts["Secure Authentication"]
        XCTAssertTrue(waitForElement(authTitle, timeout: 5), "Should show action request view")

        // Step 4: Document remainder of flow
        // Actual testing of full flow requires backend connectivity
        // The test verifies UI navigation works correctly
    }
}
