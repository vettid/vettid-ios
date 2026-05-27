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
    /// Phase 5.7 — M1 migration_status from the last warmVault response.
    /// Drives the PIN unlock screen's calm "Updating vault…" state when
    /// the value is `pending_new_enclave`, and surfaces errors when it's
    /// `failed`. Cleared on the next warm.
    @Published var lastMigrationStatus: String?

    /// Area B — per-operation device approval the user is being asked
    /// to action right now. Set by the `forApp.device.approval.request.*`
    /// observer (and by `fetchPendingDeviceApprovals` on every post-PIN-
    /// unlock pre-warm). Drives root-level navigation to
    /// `DeviceApprovalView`. Cleared by the approval screen on
    /// approve/deny/dismiss via `clearPendingDeviceApproval`.
    @Published var pendingDeviceApproval: DeviceApprovalRequest?

    /// Area G — Stage-2 agent pairing notification the user needs to
    /// authorize right now (scope picker + duration). Set by the
    /// `forApp.agent.pending-authorization` observer; cleared via
    /// `clearPendingAgentAuth`. Mirrors Android's `agentPendingAuth`
    /// LaunchedEffect in VettIDApp.kt.
    @Published var pendingAgentAuth: AgentPendingAuthNotification?

    /// Area H — agent-initiated LEASH mint awaiting owner approval.
    /// Set by the `forApp.agent.leash-mint-pending` observer; cleared
    /// via `clearPendingLeashMint`. Drives root-level routing to
    /// `LeashApprovalView`. Mirrors Android's `agentLeashMintPending`
    /// LaunchedEffect (commit ef03314).
    @Published var pendingLeashMint: AgentLeashMintPendingNotification?

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

    // MARK: - Vault clients
    //
    // These wrap NATS RPC calls to the user's vault. They're built lazily
    // after `warmVault` succeeds, when both `natsConnectionManager` has an
    // ownerSpaceId and the vault is reachable. AppState owns them so any
    // feature reachable from the SwiftUI tree can pick them up via
    // `appState.ownerSpaceClient` / `.profileClient` / etc.
    private(set) var ownerSpaceClient: OwnerSpaceClient?
    private(set) var profileClient: ProfileClient?
    private(set) var personalDataClient: PersonalDataClient?
    private(set) var secretsClient: SecretsClient?
    private(set) var grantsClient: GrantsClient?
    private(set) var actionsClient: ActionsClient?
    /// Used by the Security Audit Log surface to call `audit.query`
    /// and run the Ed25519 chain verifier on the response.
    private(set) var feedClient: FeedClient?

    /// Area B — observer task that bridges `OwnerSpaceClient.deviceApprovalRequests`
    /// into `pendingDeviceApproval`. Held here so a credential-rotation
    /// space-change can cancel the old observer before starting a new one.
    private var deviceApprovalObserverTask: Task<Void, Never>?

    /// Area G — observer task that bridges `OwnerSpaceClient.agentPendingAuth`
    /// into `pendingAgentAuth`. Held here for the same lifecycle reason
    /// as the device approval observer.
    private var agentPendingAuthObserverTask: Task<Void, Never>?

    /// Area H — observer task that bridges
    /// `OwnerSpaceClient.agentLeashMintPending` into `pendingLeashMint`.
    private var agentLeashMintObserverTask: Task<Void, Never>?

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

    /// Load the profile snapshot for the current user (Phase 2.2).
    ///
    /// Vault is the single source of truth — `Profile` is now synthesized
    /// from `PersonalDataStore` (system fields, vault-published photo)
    /// rather than read from the on-device `ProfileStore`. We don't
    /// persist user-facing profile data on-device anymore.
    ///
    /// Until the store has hydrated (early launch, before warm-up),
    /// `currentProfile` is nil. Once hydrate completes, the
    /// `syncCurrentProfileFromStore()` subscription wires a fresh value
    /// in; this entry point is now mostly a no-op preserved for the
    /// call sites that still reference it.
    func loadProfile() {
        syncCurrentProfileFromStore()
    }

    /// Update profile fields via the vault (Phase 2.2). Maps the legacy
    /// `Profile` struct back to vault namespaces and routes through
    /// `PersonalDataStore.updateField(...)` for each field that changed.
    /// Photo goes through the dedicated profile.photo.update RPC. No
    /// data writes to Keychain.
    ///
    /// Fields without a vault home (`bio`, `location`) are accepted but
    /// silently dropped — Android doesn't carry them either; they were
    /// iOS-local-only. A polish pass on `EditProfileView` will remove
    /// those inputs.
    func updateProfile(_ profile: Profile) {
        let prior = currentProfile
        // Optimistic in-memory update so the UI reflects immediately.
        currentProfile = profile

        Task { @MainActor in
            let store = PersonalDataStore.shared

            // Split displayName into first/last for the system-field
            // namespaces. Falls back to a single token in first_name.
            let nameParts = profile.displayName
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1)
            let firstName = nameParts.first.map(String.init) ?? profile.displayName
            let lastName  = nameParts.count > 1 ? String(nameParts[1]) : ""

            do {
                if firstName != (prior?.displayName.split(separator: " ").first.map(String.init) ?? "") {
                    try await store.updateField(namespace: "_system_first_name", value: firstName)
                }
                if !lastName.isEmpty,
                   lastName != (prior?.displayName.split(separator: " ").dropFirst().joined(separator: " ") ?? "") {
                    try await store.updateField(namespace: "_system_last_name", value: lastName)
                }
                if let email = profile.email, email != prior?.email {
                    try await store.updateField(namespace: "_system_email", value: email)
                }
                if let photoData = profile.photoData, photoData != prior?.photoData {
                    try await store.updatePhoto(base64: photoData.base64EncodedString())
                } else if profile.photoData == nil && prior?.photoData != nil {
                    try await store.updatePhoto(base64: nil)
                }
            } catch {
                #if DEBUG
                print("[AppState] Failed to push profile to vault: \(error)")
                #endif
                // Roll back the optimistic update on failure.
                currentProfile = prior
            }
        }
    }

    /// Phase 2.2: synthesize `currentProfile` from `PersonalDataStore`.
    /// Called once after configure() and again on every snapshot tick;
    /// keeps the legacy `Profile` view-model in sync without backing it
    /// with on-device persistence.
    func syncCurrentProfileFromStore() {
        let store = PersonalDataStore.shared
        let first = store.items.first { $0.id == "_system_first_name" }?.value ?? ""
        let last  = store.items.first { $0.id == "_system_last_name"  }?.value ?? ""
        let email = store.items.first { $0.id == "_system_email"      }?.value
        let displayName = [first, last]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let photoData: Data? = store.photoBase64.flatMap { Data(base64Encoded: $0) }

        // Preserve the user's GUID / lastUpdated / syncedAt from the
        // existing currentProfile when present; otherwise stub them.
        let guid = currentProfile?.guid ?? currentUserGuid ?? ""
        guard !displayName.isEmpty || email != nil || photoData != nil else {
            // Vault not hydrated yet — leave currentProfile as-is so
            // the UI doesn't blank.
            return
        }
        currentProfile = Profile(
            guid: guid,
            displayName: displayName.isEmpty ? "VettID User" : displayName,
            avatarUrl: nil,
            bio: nil,
            location: nil,
            email: email,
            photoData: photoData,
            syncedAt: Date(),
            lastUpdated: Date()
        )
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

    /// Called at the very end of the enrollment wizard's permissions
    /// step. Refreshes the locally-stored credential, marks the user
    /// as authenticated, and leaves vault temperature at `.warming`
    /// so the next vault op kicks off a warm (matching Android, which
    /// goes straight to the home screen without re-prompting).
    /// Without this hook the parent ContentView routes through
    /// `AuthenticationView` post-enrollment because `isAuthenticated`
    /// stays false, forcing the user to re-enter their password on a
    /// generic unlock screen — the user-visible "Unlock VettID" bounce.
    func markEnrolledAndAuthenticated(userGuid: String) {
        checkExistingCredential()
        currentUserGuid = userGuid
        isAuthenticated = true
        // The PIN exchange during enrollment already warmed the vault
        // (the supervisor returned UTKs alongside the ECIES key). Mark
        // it warm here so the parent ContentView skips VaultWarmingView
        // and goes straight to MainNavigationView — Android lands on
        // the home screen without re-prompting for the PIN.
        vaultTemperature = .warm(ttlSeconds: 3600)
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
    func warmVault(pin: String, migrateConsent: Bool = false) async throws {
        vaultWarmingError = nil

        // Load the bits required to ECIES-encrypt the PIN — mirrors
        // Android PinUnlockViewModel.verifyPin (storeEnclavePublicKey
        // + getUtkPool + getEncryptedBlob).
        guard let enclavePubKey = credentialStore.getEnclavePublicKey() else {
            vaultWarmingError = "Security key missing — please re-enroll."
            vaultTemperature = .cold
            throw VaultWarmingError.warmingFailed("Enclave public key missing")
        }
        guard let credential = try? credentialStore.retrieveFirst(),
              let utk = credential.getUnusedKey() else {
            vaultWarmingError = "No available transaction keys — please re-enroll."
            vaultTemperature = .cold
            throw VaultWarmingError.warmingFailed("No unused UTK available")
        }

        do {
            let response = try await natsConnectionManager.warmVault(
                pin: pin,
                enclavePublicKey: enclavePubKey,
                utkId: utk.keyId,
                encryptedCredentialBlob: credential.sealedCredential.isEmpty ? nil : credential.sealedCredential,
                migrateConsent: migrateConsent
            )

            // UTKs are single-use — remove the one we just spent regardless
            // of response outcome (matches Android `removeUtk` placement).
            let afterUse = credential.markingKeyUsed(keyId: utk.keyId)
            try? credentialStore.store(credential: afterUse)

            if response.success {
                vaultTemperature = .warm(ttlSeconds: response.sessionTtl)

                // Store new UTKs from vault response
                if let utks = response.utks, !utks.isEmpty {
                    storeUTKsFromWarmResponse(utks)
                }

                // Phase 5.7 — surface the M1 migration verdict to the
                // PIN unlock screen. When migrate_consent was set and
                // the vault returns `pending_new_enclave`, the screen
                // shows the calm "Updating vault…" state and re-tries;
                // `completed` records the migrated version locally so
                // we don't re-prompt; `failed` surfaces a user-facing
                // error. Empty/nil means there was nothing to migrate.
                lastMigrationStatus = response.migrationStatus
                if response.migrationStatus == "completed",
                   let version = response.migrationVersion, !version.isEmpty {
                    MigrationCompletionRecorder.shared.record(version: version)
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

    /// Build (or re-use) the vault-RPC clients now that `natsConnectionManager`
    /// has an ownerSpaceId, then hydrate `PersonalDataStore` from the vault.
    /// Triggered after `warmVault` succeeds. (Phase 0.10 — vault SSOT.)
    private func syncProfileFromVault() {
        // Keep the legacy local-profile path alive for now so anything still
        // reading `currentProfile` doesn't go blank during the migration.
        // The on-device ProfileStore is dropped in a later cleanup pass.
        loadProfile()

        guard let ownerSpaceId = natsConnectionManager.getOwnerSpaceId() else {
            #if DEBUG
            print("[AppState] syncProfileFromVault: no ownerSpaceId yet")
            #endif
            return
        }

        // (Re-)build the vault clients. Always rebuild when the space changed
        // (e.g. after credential rotation issued a new ownerSpace).
        if ownerSpaceClient?.ownerSpaceId != ownerSpaceId {
            let osc = OwnerSpaceClient(
                connectionManager: natsConnectionManager,
                ownerSpaceId: ownerSpaceId
            )
            self.ownerSpaceClient = osc
            self.profileClient = ProfileClient(ownerSpaceClient: osc)
            self.personalDataClient = PersonalDataClient(ownerSpaceClient: osc)
            self.secretsClient = SecretsClient(ownerSpaceClient: osc)
            self.grantsClient = GrantsClient(ownerSpaceClient: osc)
            self.actionsClient = ActionsClient(ownerSpaceClient: osc)
            self.feedClient = FeedClient(ownerSpaceClient: osc)

            // Phase 4.3 — wire the calling subsystem. CallCoordinator
            // is a singleton (CallKit integration requires app-wide
            // ownership), so configure once per warmed-up space.
            // Building VaultResponseHandler here gives it the same
            // OwnerSpaceClient lifetime as the rest of the vault wire.
            if let guid = currentUserGuid {
                let eventClient = VaultEventClient(ownerSpaceClient: osc)
                let responseHandler = VaultResponseHandler(vaultEventClient: eventClient)
                CallCoordinator.shared.configure(
                    connectionManager: natsConnectionManager,
                    vaultResponseHandler: responseHandler,
                    ownUserGuid: guid,
                    ownerSpaceId: ownerSpaceId
                )
                Task {
                    await responseHandler.startListening()
                    await CallCoordinator.shared.startListening()
                }
            }
        }

        guard let osc = ownerSpaceClient,
              let pc = profileClient,
              let pdc = personalDataClient else { return }

        // Configure the cache, then fan out the hydrate reads. `configure`
        // also starts the `forApp.profile.public` subscription so multi-
        // device edits land in the cache without manual refresh.
        PersonalDataStore.shared.configure(
            profileClient: pc,
            personalDataClient: pdc,
            ownerSpaceClient: osc
        )
        Task {
            // Hydrate the in-memory data cache.
            do {
                try await PersonalDataStore.shared.hydrate()
                #if DEBUG
                print("[AppState] PersonalDataStore hydrated (\(PersonalDataStore.shared.items.count) items)")
                #endif
            } catch {
                #if DEBUG
                print("[AppState] hydrate failed: \(error)")
                #endif
            }
            // Phase 2.2: synthesize currentProfile from the vault-
            // hydrated store now that the data is in memory.
            await MainActor.run { self.syncCurrentProfileFromStore() }
            // Start the presence aggregator (Phase 1.6). Idempotent.
            await PresenceAggregator.shared.attach(to: osc)
            // Phase 3.3 + 3.9: configure + hydrate the Grants
            // repository, and wire the live event stream. The repo
            // re-hydrates on every grant.* / critical-secret-use.* /
            // verify.* event so the inbox stays current without
            // pull-to-refresh.
            if let gc = self.grantsClient {
                await MainActor.run {
                    GrantsRepository.shared.configure(client: gc, ownerSpace: osc)
                }
                await GrantsRepository.shared.hydrate()
            }
            // Area B: wire the forApp.device.> subscription so per-op
            // approvals and Stage-2 pairing notifications reach the
            // app, and re-pull any approval requests that arrived
            // while we were offline (no replay on core-NATS forApp.*).
            osc.startDeviceEventSubscription()
            self.startDeviceApprovalObserver(osc)
            Task { await osc.fetchPendingDeviceApprovals() }

            // Area G: wire the forApp.agent.> subscription so Stage-2
            // agent pairings reach the app + bridge pending-auth
            // events to AppState so root-level navigation can present
            // AuthorizeAgentView.
            osc.startAgentEventSubscription()
            self.startAgentPendingAuthObserver(osc)

            // Area H: bridge the agent-initiated LEASH mint stream
            // (same forApp.agent.> subscription already started above)
            // into pendingLeashMint so root-level nav can present
            // LeashApprovalView. Plus pull the pending list once on
            // unlock so any mint request that arrived while the app
            // was offline (core-NATS forApp.* has no replay) is
            // re-surfaced. Mirrors Android 23463c8 / Area B's
            // fetchPendingDeviceApprovals.
            self.startAgentLeashMintObserver(osc)
            Task { await osc.fetchPendingLeashMints() }

            // Area D (Android ab25dc2): pre-warm the caches the
            // first post-unlock screen will read so Feed /
            // Connections render without a Loading flash. Fires
            // in parallel; each helper is self-throttling
            // (ConnectionsClient.warmList early-outs on a hot
            // cache; PersonalDataStore.hydrate is idempotent).
            // PersonalDataStore hydrate already runs above; only
            // warmList still needs to be kicked here.
            let connectionsClient = ConnectionsClient(ownerSpaceClient: osc)
            Task.detached { await connectionsClient.warmList() }
        }
    }

    /// Area B — bridge `OwnerSpaceClient.deviceApprovalRequests` into
    /// `AppState.pendingDeviceApproval` so root-level navigation can
    /// pop the user onto `DeviceApprovalView` the moment a request
    /// lands. Idempotent: re-entering `syncProfileFromVault` after a
    /// credential rotation re-uses the same OwnerSpaceClient instance
    /// (we only rebuild on owner-space change), so the observer keeps
    /// running across re-syncs. A space-change rebuilds the client
    /// AND restarts this observer (caller drops the old task by
    /// nilling `deviceApprovalObserverTask` first).
    private func startDeviceApprovalObserver(_ client: OwnerSpaceClient) {
        deviceApprovalObserverTask?.cancel()
        deviceApprovalObserverTask = Task { [weak self] in
            for await request in client.deviceApprovalRequests {
                guard let self = self else { return }
                await MainActor.run { self.pendingDeviceApproval = request }
                #if DEBUG
                print("[AppState] pendingDeviceApproval set: \(request.requestId) op=\(request.operation ?? "-")")
                #endif
            }
        }
    }

    /// Called from the approval screen on approve / deny / dismiss.
    /// Mirrors Android `AppViewModel.clearPendingDeviceApproval`.
    func clearPendingDeviceApproval() {
        pendingDeviceApproval = nil
    }

    /// Area G — bridge `OwnerSpaceClient.agentPendingAuth` into
    /// `AppState.pendingAgentAuth` so root-level navigation can
    /// present AuthorizeAgentView the moment a Stage-2 pairing
    /// arrives. Mirrors `startDeviceApprovalObserver`.
    private func startAgentPendingAuthObserver(_ client: OwnerSpaceClient) {
        agentPendingAuthObserverTask?.cancel()
        agentPendingAuthObserverTask = Task { [weak self] in
            for await notification in client.agentPendingAuth {
                guard let self = self else { return }
                await MainActor.run { self.pendingAgentAuth = notification }
                #if DEBUG
                print("[AppState] pendingAgentAuth set: \(notification.connectionId) (\(notification.agentMetadata?.agentType ?? "agent"))")
                #endif
                // Area H — surface a local banner if the app isn't
                // foregrounded so the user doesn't miss the pairing
                // window. The in-app fullScreenCover still drives
                // approval; this is purely a wake signal.
                let isActive = await MainActor.run { UIApplication.shared.applicationState == .active }
                if !isActive {
                    let label = notification.agentMetadata?.hostname.isEmpty == false
                        ? notification.agentMetadata!.hostname
                        : "Agent"
                    await LocalNotificationManager.shared.showAgentPendingAuth(
                        connectionId: notification.connectionId,
                        agentName: label,
                        agentType: notification.agentMetadata?.agentType
                    )
                }
            }
        }
    }

    /// Called from AuthorizeAgentView on Done/Deny/dismiss so the
    /// root-level cover unmounts.
    func clearPendingAgentAuth() {
        let cid = pendingAgentAuth?.connectionId
        pendingAgentAuth = nil
        if let cid {
            // Area H — clear any banner we may have raised for this
            // pairing so the lockscreen doesn't keep nagging.
            Task { await LocalNotificationManager.shared.removeAgentNotifications(connectionId: cid) }
        }
    }

    /// Area H — bridge `OwnerSpaceClient.agentLeashMintPending` into
    /// `AppState.pendingLeashMint` so root-level navigation can
    /// present LeashApprovalView the moment an agent-initiated mint
    /// arrives. Mirrors `startAgentPendingAuthObserver`.
    private func startAgentLeashMintObserver(_ client: OwnerSpaceClient) {
        agentLeashMintObserverTask?.cancel()
        agentLeashMintObserverTask = Task { [weak self] in
            for await notification in client.agentLeashMintPending {
                guard let self = self else { return }
                await MainActor.run { self.pendingLeashMint = notification }
                #if DEBUG
                print("[AppState] pendingLeashMint set: \(notification.requestId) agent=\(notification.agentName)")
                #endif
                // Area H — wake the user if the app isn't foregrounded.
                let isActive = await MainActor.run { UIApplication.shared.applicationState == .active }
                if !isActive {
                    await LocalNotificationManager.shared.showLeashMintPending(
                        requestId: notification.requestId,
                        agentName: notification.agentName,
                        scope: notification.requestedScope
                    )
                }
            }
        }
    }

    /// Called from LeashApprovalView on Approve/Deny/dismiss so the
    /// root-level cover unmounts.
    func clearPendingLeashMint() {
        let rid = pendingLeashMint?.requestId
        pendingLeashMint = nil
        if let rid {
            Task { await LocalNotificationManager.shared.removeAgentNotifications(requestId: rid) }
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
