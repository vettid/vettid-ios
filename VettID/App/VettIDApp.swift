import SwiftUI
import BackgroundTasks

@main
struct VettIDApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var deepLinkHandler = DeepLinkHandler.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(deepLinkHandler)
                .onOpenURL { url in
                    deepLinkHandler.handle(url: url)
                }
                .onChange(of: scenePhase) { newPhase in
                    handleScenePhaseChange(newPhase)
                }
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            VaultBackgroundRefresh.shared.applicationDidEnterBackground()
            PCRUpdateService.shared.onAppDidEnterBackground()
            // SECURITY: Show privacy screen to hide sensitive data in app switcher
            showBackgroundPrivacyScreen()
        case .active:
            VaultBackgroundRefresh.shared.applicationDidBecomeActive()
            PCRUpdateService.shared.onAppDidBecomeActive()
            // Remove privacy screen when app becomes active
            hideBackgroundPrivacyScreen()
        case .inactive:
            // Show privacy screen when app is about to go inactive (app switcher preview)
            showBackgroundPrivacyScreen()
        @unknown default:
            break
        }
    }

    /// Tag for identifying the privacy screen view
    private static let privacyScreenTag = 999_998

    /// Show a privacy screen to hide sensitive content in app switcher
    private func showBackgroundPrivacyScreen() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            return
        }

        // Don't add if already present
        guard window.viewWithTag(Self.privacyScreenTag) == nil else { return }

        let privacyView = UIView(frame: window.bounds)
        privacyView.tag = Self.privacyScreenTag
        privacyView.backgroundColor = UIColor.systemBackground

        // Add app icon or logo for better UX
        let imageView = UIImageView(image: UIImage(named: "AppIcon"))
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        privacyView.addSubview(imageView)

        // Add "VettID" label
        let label = UILabel()
        label.text = "VettID"
        label.font = .preferredFont(forTextStyle: .title1)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        privacyView.addSubview(label)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: privacyView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: privacyView.centerYAnchor, constant: -30),
            imageView.widthAnchor.constraint(equalToConstant: 80),
            imageView.heightAnchor.constraint(equalToConstant: 80),
            label.centerXAnchor.constraint(equalTo: privacyView.centerXAnchor),
            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 16)
        ])

        window.addSubview(privacyView)
    }

    /// Hide the privacy screen when app becomes active
    private func hideBackgroundPrivacyScreen() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            return
        }

        window.viewWithTag(Self.privacyScreenTag)?.removeFromSuperview()
    }
}

// MARK: - AppDelegate for Background Task Registration

class AppDelegate: NSObject, UIApplicationDelegate {

    /// Security status from runtime protection check
    /// Stores detected threats for use throughout the app
    private(set) static var securityStatus: RuntimeProtection.SecurityStatus?

    /// Whether the device passed security checks
    static var isDeviceSecure: Bool {
        guard let status = securityStatus else { return true }
        #if DEBUG
        // In debug builds, only block on jailbreak or tampering
        return !status.isJailbroken && !status.isTampered && !status.isFridaDetected
        #else
        return status.isSecure
        #endif
    }

    /// Detected security threats (for displaying warnings)
    static var detectedThreats: [String] {
        securityStatus?.threats ?? []
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // SECURITY: Perform runtime protection checks FIRST
        // Detects jailbreak, debugger, tampering, and instrumentation
        performRuntimeSecurityCheck()

        // Register background tasks
        VaultBackgroundRefresh.shared.registerBackgroundTasks()
        PCRUpdateService.registerBackgroundTask()

        // SECURITY: Start screen capture monitoring
        // Protects against screen recording and screenshots of sensitive data
        setupScreenProtection()

        return true
    }

    /// Perform comprehensive runtime security check
    private func performRuntimeSecurityCheck() {
        let status = RuntimeProtection.shared.checkSecurityStatus()
        Self.securityStatus = status

        #if DEBUG
        // Log security status in debug builds
        print("[Security] Runtime protection check completed")
        print("[Security] Jailbroken: \(status.isJailbroken)")
        print("[Security] Debugger: \(status.isDebuggerAttached)")
        print("[Security] Simulator: \(status.isSimulator)")
        print("[Security] Tampered: \(status.isTampered)")
        print("[Security] Frida: \(status.isFridaDetected)")
        print("[Security] RE Tools: \(status.isReverseEngineeringDetected)")
        if !status.threats.isEmpty {
            print("[Security] Threats detected: \(status.threats.joined(separator: ", "))")
        }
        #endif

        // Log security events (in production, send to security telemetry)
        if !status.threats.isEmpty {
            logSecurityEvent(threats: status.threats)
        }
    }

    /// Log security events for auditing
    private func logSecurityEvent(threats: [String]) {
        // In production, this would send to a security monitoring service
        // For now, we store it for the app to handle
        #if !DEBUG
        // Could integrate with analytics/crash reporting here
        // e.g., Sentry, Firebase Crashlytics, etc.
        #endif
    }

    /// Configure screen protection to detect and respond to screen capture attempts
    private func setupScreenProtection() {
        let protection = ScreenProtection.shared

        // Enable automatic privacy overlay during screen recording/mirroring
        protection.autoShowPrivacyOverlay = true

        // Log screen capture attempts (for security auditing)
        protection.onScreenCaptureDetected = {
            #if DEBUG
            print("[Security] Screen capture detected - privacy overlay shown")
            #endif
            // In production, could send security telemetry here
        }

        // Log screenshot attempts
        protection.onScreenshotDetected = {
            #if DEBUG
            print("[Security] Screenshot detected")
            #endif
            // Could show a warning toast to user or log security event
        }

        // Start monitoring
        protection.startMonitoring()
    }
}

@MainActor
class AppState: ObservableObject {
    // Authentication state
    @Published var isAuthenticated = false
    @Published var hasCredential = false
    @Published var currentUserGuid: String?
    @Published var vaultStatus: VaultStatus?

    // User profile
    @Published var currentProfile: Profile?

    // Vault state tracking
    @Published var hasActiveVault: Bool = false
    @Published var vaultInstanceId: String?

    // Vault temperature state (Architecture v2.0 Section 5.8)
    // warm = DEK loaded (vault operations work)
    // cold = DEK not loaded (need PIN to warm)
    @Published var vaultTemperature: VaultTemperature = .unknown
    @Published var vaultWarmingError: String?

    // NATS connection manager for vault operations
    lazy var natsConnectionManager: NatsConnectionManager = {
        NatsConnectionManager(userGuidProvider: { [weak self] in
            self?.currentUserGuid
        })
    }()

    // Deep link navigation state
    @Published var pendingNavigation: PendingNavigation?

    // User preferences
    @Published var preferences: UserPreferences {
        didSet { preferences.save() }
    }

    // Computed properties
    var isActive: Bool { hasCredential && hasActiveVault }

    var theme: AppTheme {
        get { preferences.theme }
        set {
            preferences.theme = newValue
            preferences.save()
        }
    }

    var appLock: AppLockSettings {
        get { preferences.appLock }
        set {
            preferences.appLock = newValue
            preferences.save()
        }
    }

    private let credentialStore = CredentialStore()
    private let profileStore = ProfileStore()

    /// Flag indicating if running in UI test mode
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    /// Flag indicating if UI tests should simulate enrolled state
    static var isUITestingEnrolled: Bool {
        ProcessInfo.processInfo.arguments.contains("--enrolled")
    }

    /// Flag indicating if UI tests should simulate authenticated state
    static var isUITestingAuthenticated: Bool {
        ProcessInfo.processInfo.arguments.contains("--authenticated")
    }

    init() {
        self.preferences = UserPreferences.load()

        // Handle UI testing mode
        if Self.isUITesting {
            setupForUITesting()
        } else {
            checkExistingCredential()
            loadProfile()
        }
    }

    /// Configure app state for UI testing
    private func setupForUITesting() {
        if Self.isUITestingEnrolled {
            // Simulate enrolled state - check for real credential or use mock
            checkExistingCredential()
            loadProfile()
            if Self.isUITestingAuthenticated {
                isAuthenticated = true
            }
        } else {
            // Not enrolled - ensure welcome screen is shown
            hasCredential = false
            isAuthenticated = false
            currentUserGuid = nil
            vaultStatus = nil
        }
    }

    /// Load stored profile for current user
    func loadProfile() {
        if let guid = currentUserGuid {
            currentProfile = try? profileStore.retrieve(userGuid: guid)
        } else {
            currentProfile = try? profileStore.retrieveFirst()
        }
    }

    /// Update and save profile
    func updateProfile(_ profile: Profile) {
        do {
            try profileStore.store(profile: profile)
            currentProfile = profile
        } catch {
            #if DEBUG
            print("Failed to save profile: \(error)")
            #endif
        }
    }

    func checkExistingCredential() {
        hasCredential = credentialStore.hasStoredCredential()
        if let credential = try? credentialStore.retrieveFirst() {
            currentUserGuid = credential.userGuid
            if let status = credential.vaultStatus {
                vaultStatus = parseVaultStatus(status)
                // Update active vault state based on status
                if case .running(let instanceId) = vaultStatus {
                    hasActiveVault = true
                    vaultInstanceId = instanceId
                } else {
                    hasActiveVault = false
                    vaultInstanceId = nil
                }
            }
        }
    }

    func refreshCredentialState() {
        checkExistingCredential()
    }

    /// Sign out - clears authentication but keeps credentials
    func signOut() {
        isAuthenticated = false
    }

    /// Lock the app using app lock (if enabled)
    func lock() {
        if preferences.appLock.isEnabled {
            AppLockService.shared.lock()
        } else {
            // If app lock is not enabled, just sign out
            isAuthenticated = false
        }
        // Mark vault as cold when app is locked
        vaultTemperature = .cold
    }

    // MARK: - Vault Warming (Architecture v2.0 Section 5.8)

    /// Check if vault needs to be warmed before operations
    var needsVaultWarming: Bool {
        vaultTemperature.isCold || vaultTemperature == .unknown
    }

    /// Warm the vault with PIN
    ///
    /// Sends the PIN to the supervisor via NATS to derive DEK and load it into memory.
    /// Must be called on app open before vault operations can proceed.
    /// On success, stores new UTKs and triggers profile sync.
    ///
    /// - Parameter pin: User's 6-digit PIN
    /// - Throws: NatsConnectionError on failure
    func warmVault(pin: String) async throws {
        vaultWarmingError = nil

        do {
            let response = try await natsConnectionManager.warmVault(pin: pin)

            if response.success {
                vaultTemperature = .warm(ttlSeconds: response.sessionTtl)

                // Store new UTKs from vault response
                if let utks = response.utks, !utks.isEmpty {
                    storeUTKsFromWarmResponse(utks)
                }

                // Sync profile data from vault after successful warming
                syncProfileFromVault()
            } else {
                vaultWarmingError = response.message ?? "Failed to warm vault"
                if let remaining = response.remainingAttempts, remaining <= 0 {
                    vaultTemperature = .lockedOut(retryAfter: Date().addingTimeInterval(300))
                } else {
                    vaultTemperature = .cold
                }
                throw VaultWarmingError.warmingFailed(response.message ?? "Unknown error")
            }
        } catch let error as VaultWarmingError {
            throw error
        } catch {
            vaultWarmingError = error.localizedDescription
            throw VaultWarmingError.warmingFailed(error.localizedDescription)
        }
    }

    /// Store UTKs returned from vault warming response
    private func storeUTKsFromWarmResponse(_ utks: [VaultWarmResponse.UTKInfo]) {
        guard let credential = try? credentialStore.retrieveFirst() else { return }

        let storedUTKs = utks.map { utk in
            StoredUTK(
                keyId: utk.id,
                publicKey: utk.publicKey,
                algorithm: "X25519",
                isUsed: false
            )
        }

        // Update credential with new UTKs
        let updated = StoredCredential(
            userGuid: credential.userGuid,
            sealedCredential: credential.sealedCredential,
            enclavePublicKey: credential.enclavePublicKey,
            backupKey: credential.backupKey,
            ledgerAuthToken: credential.ledgerAuthToken,
            transactionKeys: storedUTKs,
            createdAt: credential.createdAt,
            lastUsedAt: Date(),
            vaultStatus: credential.vaultStatus,
            localData: credential.localData
        )

        try? credentialStore.store(credential: updated)

        #if DEBUG
        print("[AppState] Stored \(utks.count) UTKs from vault warming")
        #endif
    }

    /// Sync profile data from vault after warming
    private func syncProfileFromVault() {
        // Load profile from local store first
        loadProfile()

        // In production: fetch system fields (firstName, lastName, email)
        // from vault via NATS and update profile
        #if DEBUG
        print("[AppState] Profile sync triggered after vault warming")
        #endif
    }

    /// Mark vault as cold (e.g., after background timeout)
    func markVaultCold() {
        vaultTemperature = .cold
        natsConnectionManager.markVaultCold()
    }

    /// Reset vault temperature on logout
    func resetVaultTemperature() {
        vaultTemperature = .unknown
        natsConnectionManager.resetVaultTemperature()
    }

    /// Full sign out - clears credentials (requires re-enrollment)
    func fullSignOut() {
        isAuthenticated = false
        hasCredential = false
        currentUserGuid = nil
        vaultStatus = nil
        hasActiveVault = false
        vaultInstanceId = nil
        currentProfile = nil

        // Reset vault temperature
        resetVaultTemperature()

        // Clear all keychain data
        clearAllKeychainData()

        // Cancel background sync tasks
        VaultBackgroundRefresh.shared.onLogout()
    }

    /// Clear all stored keychain data
    private func clearAllKeychainData() {
        // Clear stored credentials
        try? credentialStore.deleteAll()

        // Clear profile data
        try? profileStore.deleteAll()

        // Clear secrets
        let secretsStore = SecretsStore()
        try? secretsStore.deleteAll()

        // Clear secure keys
        try? SecureKeyStore().deleteAllKeys()
    }

    private func parseVaultStatus(_ status: String) -> VaultStatus {
        switch status.uppercased() {
        case "PENDING_ENROLLMENT", "PENDING-ENROLLMENT":
            return .pendingEnrollment
        case "PENDING_PROVISION", "PENDING-PROVISION":
            return .pendingProvision
        case "PROVISIONING":
            return .provisioning(progress: nil)
        case "INITIALIZING":
            return .initializing
        case "RUNNING":
            return .running(instanceId: "")
        case "STOPPED":
            return .stopped
        case "TERMINATED":
            return .terminated
        default:
            return .stopped
        }
    }

    // MARK: - Navigation Helpers

    /// Navigate to a specific connection for messaging
    func navigateToMessage(connectionId: String) {
        pendingNavigation = .message(connectionId: connectionId)
    }

    /// Navigate to connect flow with invitation code
    func navigateToConnect(code: String) {
        pendingNavigation = .connect(code: code)
    }

    /// Navigate to vault services status
    func navigateToVaultStatus() {
        pendingNavigation = .vaultStatus
    }

    /// Clear pending navigation after it's been handled
    func clearPendingNavigation() {
        pendingNavigation = nil
    }
}

// MARK: - Pending Navigation

/// Represents a pending navigation action from a deep link
enum PendingNavigation: Equatable {
    case message(connectionId: String)
    case connect(code: String)
    case vaultStatus
}

// MARK: - Vault Warming Error

/// Errors that can occur during vault warming
enum VaultWarmingError: Error, LocalizedError {
    case warmingFailed(String)
    case lockedOut(retryAfter: Date?)
    case notConnected
    case invalidPIN

    var errorDescription: String? {
        switch self {
        case .warmingFailed(let message):
            return message
        case .lockedOut(let retryAfter):
            if let date = retryAfter {
                let formatter = RelativeDateTimeFormatter()
                return "Locked out. Try again \(formatter.localizedString(for: date, relativeTo: Date()))"
            }
            return "Too many failed attempts. Please try again later."
        case .notConnected:
            return "Not connected to vault. Please check your connection."
        case .invalidPIN:
            return "Invalid PIN format. PIN must be 6 digits."
        }
    }
}
