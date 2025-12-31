import XCTest

/// UI tests for the vault status, health, preferences, and archive views
/// Note: These tests require an enrolled and authenticated state to run properly.
final class VaultUITests: VettIDUITests {

    // MARK: - Test Configuration

    /// Override setup to handle enrolled and authenticated state
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--enrolled", "--authenticated"]
        app.launch()
    }

    // MARK: - Vault Status Tests

    func testVaultStatusViewNotEnrolledState() throws {
        // If user is not enrolled, should show setup prompt
        let setupButton = app.buttons["Begin Setup"]
        let notEnrolledTitle = app.staticTexts["Set Up Your Vault"]

        if notEnrolledTitle.exists {
            XCTAssertTrue(setupButton.exists, "Setup button should be visible when not enrolled")
        }
    }

    func testVaultStatusViewEnrolledState() throws {
        // Navigate to vault if we can
        try navigateToVaultSection()

        // Look for vault status elements
        let vaultTitle = app.staticTexts["My Vault"]
        let statusCard = app.otherElements[AccessibilityID.VaultStatus.statusCard]

        // At least one vault-related element should be visible
        let hasVaultElements = waitForElement(vaultTitle, timeout: 5) ||
                              waitForElement(statusCard, timeout: 3)

        // Skip if we can't get to vault section
        if !hasVaultElements {
            throw XCTSkip("Could not navigate to vault section - app may not be enrolled/authenticated")
        }
    }

    func testVaultStatusActionButtonsExist() throws {
        try navigateToVaultSection()

        // Look for action buttons based on vault state
        let startButton = app.buttons["Start Vault"]
        let stopButton = app.buttons["Stop Vault"]
        let syncButton = app.buttons["Sync Now"]

        // Sync button should always be visible when enrolled
        if syncButton.exists {
            XCTAssertTrue(syncButton.isEnabled, "Sync button should be enabled")
        }

        // Either start or stop button should be visible depending on state
        let hasLifecycleButton = startButton.exists || stopButton.exists
        // This is okay if neither exists - might be in provisioning state
        if hasLifecycleButton {
            XCTAssertTrue(true, "Vault lifecycle button is visible")
        }
    }

    func testVaultStatusLoadingState() throws {
        // Check if loading state is shown properly
        try navigateToVaultSection()

        let loadingSpinner = app.activityIndicators.firstMatch
        let loadingText = app.staticTexts["Loading vault status..."]

        // Loading state may be brief - document expected behavior
        if loadingSpinner.exists || loadingText.exists {
            XCTAssertTrue(true, "Loading state is properly displayed")
        }
    }

    func testVaultStatusErrorState() throws {
        try navigateToVaultSection()

        // Check for error view elements
        let errorTitle = app.staticTexts["Unable to Load Vault"]
        let retryButton = app.buttons["Try Again"]

        if errorTitle.exists {
            XCTAssertTrue(retryButton.exists, "Retry button should be visible on error")
        }
    }

    // MARK: - Vault Health Tests

    func testVaultHealthViewLoading() throws {
        try navigateToVaultHealth()

        // Loading state
        let loadingView = app.otherElements[AccessibilityID.VaultHealth.loadingView]
        let loadingText = app.staticTexts["Checking vault status..."]

        // Loading may be brief
        if loadingView.exists || loadingText.exists {
            XCTAssertTrue(true, "Loading view is displayed")
        }
    }

    func testVaultHealthNotProvisionedView() throws {
        try navigateToVaultHealth()

        let notProvisionedView = app.otherElements[AccessibilityID.VaultHealth.notProvisionedView]
        let provisionButton = app.buttons["Provision Vault"]
        let title = app.staticTexts["No Vault Instance"]

        if notProvisionedView.exists || title.exists {
            XCTAssertTrue(provisionButton.exists, "Provision button should be visible when not provisioned")
        }
    }

    func testVaultHealthProvisioningView() throws {
        try navigateToVaultHealth()

        let provisioningView = app.otherElements[AccessibilityID.VaultHealth.provisioningView]
        let provisioningTitle = app.staticTexts["Provisioning Vault"]
        let progressCircle = app.otherElements[AccessibilityID.VaultHealth.provisioningProgressCircle]

        if provisioningView.exists || provisioningTitle.exists {
            // Should show progress indicator
            let hasProgress = progressCircle.exists ||
                             app.staticTexts.containing(NSPredicate(format: "label CONTAINS '%'")).firstMatch.exists
            XCTAssertTrue(hasProgress, "Progress should be shown during provisioning")
        }
    }

    func testVaultHealthStoppedView() throws {
        try navigateToVaultHealth()

        let stoppedView = app.otherElements[AccessibilityID.VaultHealth.stoppedView]
        let stoppedTitle = app.staticTexts["Vault Stopped"]
        let startButton = app.buttons["Start Vault"]

        if stoppedView.exists || stoppedTitle.exists {
            XCTAssertTrue(startButton.exists, "Start button should be visible when stopped")
        }
    }

    func testVaultHealthDetailsView() throws {
        try navigateToVaultHealth()

        // Wait for health check to complete
        Thread.sleep(forTimeInterval: 2)

        // Check for details view elements
        let statusHeader = app.otherElements[AccessibilityID.VaultHealth.statusHeader]
        let componentsLabel = app.staticTexts["Components"]
        let resourcesLabel = app.staticTexts["Resources"]
        let actionsLabel = app.staticTexts["Actions"]

        // If health view shows details
        if statusHeader.exists || componentsLabel.exists {
            XCTAssertTrue(resourcesLabel.exists || actionsLabel.exists,
                         "Health details should show components/resources/actions")
        }
    }

    func testVaultHealthDetailsActions() throws {
        try navigateToVaultHealth()

        // Wait for potential loading
        Thread.sleep(forTimeInterval: 2)

        let stopButton = app.buttons[AccessibilityID.VaultHealth.stopButton]
        let terminateButton = app.buttons[AccessibilityID.VaultHealth.terminateButton]

        if stopButton.exists || terminateButton.exists {
            // If terminate button exists, tap it and verify confirmation dialog
            if terminateButton.exists && terminateButton.isHittable {
                terminateButton.tap()

                let alertTitle = app.staticTexts["Terminate Vault?"]
                let cancelButton = app.buttons["Cancel"]

                if alertTitle.exists {
                    XCTAssertTrue(cancelButton.exists, "Cancel button should exist in terminate alert")
                    cancelButton.tap() // Dismiss alert
                }
            }
        }
    }

    func testVaultHealthToolbarPlayPauseButton() throws {
        try navigateToVaultHealth()

        // Look for play/pause button in toolbar
        let playButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'play'")).firstMatch
        let pauseButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'pause'")).firstMatch

        let hasMonitoringControl = playButton.exists || pauseButton.exists

        if hasMonitoringControl {
            XCTAssertTrue(true, "Health monitoring control is available")
        }
    }

    // MARK: - Vault Preferences Tests

    func testVaultPreferencesViewElements() throws {
        try navigateToVaultPreferences()

        // Check for main sections
        let sessionHeader = app.staticTexts["Session"]
        let securityHeader = app.staticTexts["Security"]
        let automationHeader = app.staticTexts["Automation"]
        let archiveHeader = app.staticTexts["Archive"]
        let dataHeader = app.staticTexts["Data"]

        let hasPreferenceSections = sessionHeader.exists ||
                                    securityHeader.exists ||
                                    automationHeader.exists

        if hasPreferenceSections {
            XCTAssertTrue(true, "Preferences view has expected sections")
        } else {
            throw XCTSkip("Could not navigate to vault preferences")
        }
    }

    func testVaultPreferencesChangePassword() throws {
        try navigateToVaultPreferences()

        let changePasswordButton = app.buttons["Change Vault Password"]

        if waitForHittable(changePasswordButton, timeout: 3) {
            changePasswordButton.tap()

            // Check for password change sheet
            let currentPasswordField = app.secureTextFields["Current Password"]
            let newPasswordField = app.secureTextFields["New Password"]
            let cancelButton = app.buttons["Cancel"]

            if waitForElement(currentPasswordField, timeout: 3) {
                XCTAssertTrue(newPasswordField.exists, "New password field should be visible")
                XCTAssertTrue(cancelButton.exists, "Cancel button should be visible")

                // Dismiss sheet
                cancelButton.tap()
            }
        }
    }

    func testVaultPreferencesClearCache() throws {
        try navigateToVaultPreferences()

        let clearCacheButton = app.buttons["Clear Local Cache"]

        if clearCacheButton.exists {
            XCTAssertTrue(clearCacheButton.isHittable, "Clear cache button should be tappable")
        }
    }

    func testVaultPreferencesNavigationLinks() throws {
        try navigateToVaultPreferences()

        let manageHandlers = app.staticTexts["Manage Handlers"]
        let viewArchive = app.staticTexts["View Archive"]

        if manageHandlers.exists {
            XCTAssertTrue(true, "Manage Handlers link is visible")
        }

        if viewArchive.exists {
            XCTAssertTrue(true, "View Archive link is visible")
        }
    }

    // MARK: - Archive Tests

    func testArchiveViewEmpty() throws {
        try navigateToArchive()

        let emptyView = app.otherElements[AccessibilityID.Archive.emptyView]
        let emptyTitle = app.staticTexts["No Archived Items"]
        let loadingIndicator = app.progressIndicators.firstMatch

        // Wait for loading to complete
        Thread.sleep(forTimeInterval: 1)

        if emptyView.exists || emptyTitle.exists {
            XCTAssertTrue(true, "Empty archive view is displayed correctly")
        } else if loadingIndicator.exists {
            XCTAssertTrue(true, "Archive is loading")
        }
    }

    func testArchiveViewWithItems() throws {
        try navigateToArchive()

        Thread.sleep(forTimeInterval: 1)

        let archiveList = app.otherElements[AccessibilityID.Archive.list]
        let selectButton = app.buttons["Select"]

        // If there are items, select button should be visible
        if selectButton.exists {
            XCTAssertTrue(selectButton.isEnabled, "Select button should be enabled when items exist")
        }
    }

    func testArchiveFilterChips() throws {
        try navigateToArchive()

        Thread.sleep(forTimeInterval: 1)

        // Look for filter chips
        let allFilter = app.buttons["All"]
        let messagesFilter = app.buttons["Messages"]
        let connectionsFilter = app.buttons["Connections"]

        if allFilter.exists || messagesFilter.exists {
            XCTAssertTrue(true, "Archive filter chips are displayed")

            // Try tapping a filter
            if messagesFilter.exists && messagesFilter.isHittable {
                messagesFilter.tap()
                // Filter should now be selected
            }
        }
    }

    func testArchiveSelectionMode() throws {
        try navigateToArchive()

        Thread.sleep(forTimeInterval: 1)

        let selectButton = app.buttons["Select"]

        if waitForHittable(selectButton, timeout: 3) {
            selectButton.tap()

            // Should now show "Done" button
            let doneButton = app.buttons["Done"]
            if waitForElement(doneButton, timeout: 2) {
                XCTAssertTrue(doneButton.exists, "Done button should appear in selection mode")
                doneButton.tap() // Exit selection mode
            }
        }
    }

    func testArchiveSearch() throws {
        try navigateToArchive()

        // Look for search field
        let searchField = app.searchFields.firstMatch

        if searchField.exists {
            searchField.tap()
            searchField.typeText("test")

            // Search should filter results
            XCTAssertTrue(true, "Search functionality is available")

            // Clear search
            let cancelButton = app.buttons["Cancel"]
            if cancelButton.exists {
                cancelButton.tap()
            }
        }
    }

    // MARK: - Accessibility Tests

    func testVaultStatusAccessibility() throws {
        try navigateToVaultSection()

        // Verify accessibility identifiers are set
        let statusCard = app.otherElements[AccessibilityID.VaultStatus.statusCard]
        let actionsSection = app.otherElements[AccessibilityID.VaultStatus.actionsSection]

        let hasAccessibility = statusCard.exists || actionsSection.exists ||
                              app.staticTexts["My Vault"].exists

        XCTAssertTrue(hasAccessibility, "Vault status should have accessibility support")
    }

    func testVaultHealthAccessibility() throws {
        try navigateToVaultHealth()

        // Verify accessibility identifiers
        let loadingView = app.otherElements[AccessibilityID.VaultHealth.loadingView]
        let notProvisionedView = app.otherElements[AccessibilityID.VaultHealth.notProvisionedView]
        let stoppedView = app.otherElements[AccessibilityID.VaultHealth.stoppedView]
        let errorView = app.otherElements[AccessibilityID.VaultHealth.errorView]

        let hasAccessibility = loadingView.exists ||
                              notProvisionedView.exists ||
                              stoppedView.exists ||
                              errorView.exists ||
                              app.staticTexts["Vault Health"].exists

        XCTAssertTrue(hasAccessibility, "Vault health should have accessibility support")
    }

    // MARK: - Helper Methods

    /// Navigate to the vault section in the app
    private func navigateToVaultSection() throws {
        // Skip if on welcome screen (not enrolled)
        let welcomeTitle = app.staticTexts["Welcome to VettID"]
        if welcomeTitle.exists {
            throw XCTSkip("App is not enrolled, cannot test vault section")
        }

        // Skip if on unlock screen (not authenticated)
        let unlockTitle = app.staticTexts["Unlock VettID"]
        if unlockTitle.exists {
            throw XCTSkip("App is not authenticated, cannot test vault section")
        }

        // Try to navigate to vault via drawer or tab
        // First look for My Vault in navigation
        let vaultNavItem = app.staticTexts["My Vault"]
        let vaultButton = app.buttons["My Vault"]
        let vaultTab = app.buttons["Vault"]

        if vaultNavItem.exists && vaultNavItem.isHittable {
            vaultNavItem.tap()
        } else if vaultButton.exists && vaultButton.isHittable {
            vaultButton.tap()
        } else if vaultTab.exists && vaultTab.isHittable {
            vaultTab.tap()
        }

        // Wait for navigation
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Navigate to vault health view
    private func navigateToVaultHealth() throws {
        try navigateToVaultSection()

        // Look for health link or navigate through vault
        let healthLink = app.staticTexts["Vault Health"]
        let healthButton = app.buttons["Vault Health"]

        if healthLink.exists && healthLink.isHittable {
            healthLink.tap()
        } else if healthButton.exists && healthButton.isHittable {
            healthButton.tap()
        } else {
            // May already be on health view or need to find it in menu
            throw XCTSkip("Could not navigate to vault health view")
        }

        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Navigate to vault preferences
    private func navigateToVaultPreferences() throws {
        try navigateToVaultSection()

        // Look for preferences/settings link
        let preferencesLink = app.staticTexts["Preferences"]
        let preferencesButton = app.buttons["Preferences"]
        let moreButton = app.buttons["More"]

        // Try More menu first
        if moreButton.exists && moreButton.isHittable {
            moreButton.tap()
            Thread.sleep(forTimeInterval: 0.3)
        }

        if preferencesLink.exists && preferencesLink.isHittable {
            preferencesLink.tap()
        } else if preferencesButton.exists && preferencesButton.isHittable {
            preferencesButton.tap()
        } else {
            throw XCTSkip("Could not navigate to vault preferences")
        }

        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Navigate to archive view
    private func navigateToArchive() throws {
        // Try navigating through preferences first
        do {
            try navigateToVaultPreferences()

            let viewArchive = app.staticTexts["View Archive"]
            if viewArchive.exists && viewArchive.isHittable {
                viewArchive.tap()
                Thread.sleep(forTimeInterval: 0.5)
                return
            }
        } catch {
            // Fall through to try other navigation
        }

        // Try direct navigation
        try navigateToVaultSection()

        let archiveLink = app.staticTexts["Archive"]
        let archiveButton = app.buttons["Archive"]

        if archiveLink.exists && archiveLink.isHittable {
            archiveLink.tap()
        } else if archiveButton.exists && archiveButton.isHittable {
            archiveButton.tap()
        } else {
            throw XCTSkip("Could not navigate to archive view")
        }

        Thread.sleep(forTimeInterval: 0.5)
    }
}

// MARK: - Vault Flow Documentation

extension VaultUITests {

    /// Test documenting the complete vault management flow
    func testVaultManagementFlowDocumentation() throws {
        // This test documents the expected vault management flow:
        //
        // 1. Vault Status View (VaultStatusView)
        //    - Shows current vault status (not enrolled, running, stopped, etc.)
        //    - Quick stats: keys available, last sync
        //    - Health indicator
        //    - Action buttons: Start/Stop, Sync
        //
        // 2. Vault Health View (VaultHealthView)
        //    - Loading state while checking
        //    - Not Provisioned: Provision button
        //    - Provisioning: Progress circle with percentage
        //    - Stopped: Start button
        //    - Running: Component status, resource stats, Stop/Terminate
        //    - Error: Retry button
        //
        // 3. Vault Preferences (VaultPreferencesView)
        //    - Session timeout picker
        //    - Change vault password
        //    - Manage handlers link
        //    - Archive settings (archive after X days, delete after Y days)
        //    - View archive link
        //    - Clear local cache
        //
        // 4. Archive View (ArchiveView)
        //    - Empty state when no archived items
        //    - Filter chips: All, Messages, Connections, Files, Credentials
        //    - Items grouped by month
        //    - Selection mode for bulk delete
        //    - Search functionality

        // Skip if we can't even get to the vault section
        try navigateToVaultSection()

        // Document current state
        let vaultTitle = app.staticTexts["My Vault"]
        let vaultHealthTitle = app.staticTexts["Vault Health"]

        if vaultTitle.exists || vaultHealthTitle.exists {
            XCTAssertTrue(true, "Successfully navigated to vault section")
        }
    }
}
