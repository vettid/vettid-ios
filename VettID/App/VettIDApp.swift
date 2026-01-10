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
        case .active:
            VaultBackgroundRefresh.shared.applicationDidBecomeActive()
            PCRUpdateService.shared.onAppDidBecomeActive()
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}

// MARK: - AppDelegate for Background Task Registration

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register background tasks
        VaultBackgroundRefresh.shared.registerBackgroundTasks()
        PCRUpdateService.registerBackgroundTask()
        return true
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

    init() {
        self.preferences = UserPreferences.load()
        checkExistingCredential()
        loadProfile()
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
    ///
    /// - Parameter pin: User's 6-digit PIN
    /// - Throws: NatsConnectionError on failure
    func warmVault(pin: String) async throws {
        vaultWarmingError = nil

        do {
            let response = try await natsConnectionManager.warmVault(pin: pin)

            if response.success {
                vaultTemperature = .warm(ttlSeconds: response.sessionTtl)
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
