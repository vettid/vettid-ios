import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var deepLinkHandler: DeepLinkHandler
    @StateObject private var lockService = AppLockService.shared
    @Environment(\.scenePhase) private var scenePhase

    // Deep link navigation state
    @State private var showEnrollmentFromDeepLink = false
    @State private var deepLinkEnrollToken: String?

    // Background time tracking for vault cooling
    @State private var backgroundTime: Date?

    // Security warning state
    @State private var showSecurityWarning = false
    @State private var securityWarningDismissed = false

    var body: some View {
        ZStack {
            // Main content
            Group {
                if !appState.hasCredential {
                    WelcomeView()
                } else if !appState.isAuthenticated {
                    AuthenticationView()
                } else if appState.needsVaultWarming {
                    // Vault is cold - need PIN to warm it (Architecture v2.0 Section 5.8)
                    VaultWarmingView {
                        // Successfully warmed vault
                    }
                } else {
                    MainNavigationView()
                }
            }

            // App lock overlay
            if lockService.isLocked && appState.isAuthenticated {
                AppLockView(lockService: lockService)
                    .transition(.opacity)
                    .zIndex(100)
            }

            // Security warning overlay (shows on compromised devices)
            if showSecurityWarning && !securityWarningDismissed {
                SecurityWarningView(
                    threats: AppDelegate.detectedThreats,
                    onContinue: {
                        securityWarningDismissed = true
                    },
                    onExit: {
                        exit(0)
                    }
                )
                .background(Color(.systemBackground))
                .transition(.opacity)
                .zIndex(200)
            }
        }
        .onAppear {
            // Check security status on first appearance
            checkDeviceSecurity()
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onChange(of: deepLinkHandler.pendingDeepLink) { deepLink in
            handleDeepLink(deepLink)
        }
        .sheet(isPresented: $showEnrollmentFromDeepLink) {
            if let token = deepLinkEnrollToken {
                DeepLinkEnrollmentView(token: token)
                    .environmentObject(appState)
            }
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            lockService.appDidEnterBackground()
            // Store background time for vault cooling check
            backgroundTime = Date()
        case .active:
            lockService.appWillEnterForeground()
            // Check if vault should be marked cold based on background duration
            checkVaultCooling()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// Check if vault should be marked cold after returning from background
    private func checkVaultCooling() {
        guard let bgTime = backgroundTime else { return }
        backgroundTime = nil

        let backgroundDuration = Date().timeIntervalSince(bgTime)
        // Cool vault after 5 minutes in background (matches app lock timeout)
        let vaultCoolTimeout: TimeInterval = 300

        if backgroundDuration >= vaultCoolTimeout && appState.vaultTemperature.isWarm {
            #if DEBUG
            print("[ContentView] Vault cooled after \(Int(backgroundDuration))s in background")
            #endif
            appState.markVaultCold()
        }
    }

    private func handleDeepLink(_ deepLink: DeepLink?) {
        guard let deepLink = deepLink else { return }

        // Clear the pending deep link
        deepLinkHandler.clearPendingDeepLink()

        switch deepLink {
        case .enroll(let token):
            // If not enrolled, start enrollment with the token
            if !appState.hasCredential {
                deepLinkEnrollToken = token
                showEnrollmentFromDeepLink = true
            }

        case .connect(let code):
            // If authenticated, handle connection invitation
            if appState.isAuthenticated {
                appState.navigateToConnect(code: code)
            }

        case .message(let connectionId):
            // If authenticated, navigate to conversation
            if appState.isAuthenticated {
                appState.navigateToMessage(connectionId: connectionId)
            }

        case .vault:
            // If authenticated, navigate to vault
            if appState.isAuthenticated {
                appState.navigateToVaultStatus()
            }

        case .unknown:
            break
        }
    }

    /// Check device security status and show warning if compromised
    private func checkDeviceSecurity() {
        // Only check once per app launch
        guard !securityWarningDismissed else { return }

        // Check if device is compromised
        if !AppDelegate.isDeviceSecure {
            showSecurityWarning = true
        }
    }
}

// MARK: - Deep Link Enrollment View

struct DeepLinkEnrollmentView: View {
    let token: String
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = EnrollmentViewModel()

    var body: some View {
        NavigationView {
            EnrollmentContainerView()
                .environmentObject(appState)
                .onAppear {
                    // Start enrollment with the deep link token
                    Task {
                        await viewModel.handleScannedCode(token)
                    }
                }
        }
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    @State private var showRecovery = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Logo/Icon
                Image("VettIDLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .accessibilityIdentifier("welcome.logo")

                // Title
                Text("Welcome to VettID")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .accessibilityIdentifier("welcome.title")

                // Subtitle
                Text("Secure credential management\nfor your personal vault")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("welcome.subtitle")

                Spacer()

                // Primary action - QR scan
                NavigationLink(destination: EnrollmentContainerView()) {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("welcome.scanQRButton")

                // Secondary action - manual entry
                NavigationLink(destination: ManualEnrollmentView()) {
                    Text("Enter code manually")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("welcome.enterCodeButton")

                // Recovery option
                Button {
                    showRecovery = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle")
                        Text("Recover existing account")
                    }
                    .foregroundColor(.secondary)
                }
                .accessibilityIdentifier("welcome.recoverButton")

                Spacer()
                    .frame(height: 40)
            }
            .padding()
            .sheet(isPresented: $showRecovery) {
                WelcomeRecoveryView()
            }
        }
    }
}

// MARK: - Welcome Recovery View

/// Recovery view accessible from the welcome screen (before enrollment)
/// This allows users to recover their credential on a new device
struct WelcomeRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var isRequestingRecovery = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var recoveryRequested = false
    @State private var showQrScanner = false

    var body: some View {
        NavigationStack {
            if recoveryRequested {
                recoveryRequestedView
            } else {
                recoveryRequestForm
            }
        }
    }

    private var recoveryRequestForm: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "person.badge.clock")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Recover Your Account")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("If you have a backup of your credential, you can recover it on this device.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)

            // Recovery options
            VStack(spacing: 16) {
                // QR Code recovery (instant)
                Button {
                    showQrScanner = true
                } label: {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title2)
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scan Recovery QR Code")
                                .fontWeight(.medium)
                            Text("Instant recovery from Account Portal")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                .foregroundColor(.primary)

                // Email recovery (24-hour delay)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Or request recovery via email")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    TextField("Email address", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Text("Recovery via email has a 24-hour security delay")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
            .padding(.horizontal)

            Spacer()

            // Request recovery button
            Button {
                requestRecovery()
            } label: {
                HStack {
                    if isRequestingRecovery {
                        ProgressView()
                            .tint(.white)
                            .padding(.trailing, 4)
                    }
                    Text(isRequestingRecovery ? "Requesting..." : "Request Email Recovery")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(email.isEmpty || isRequestingRecovery ? Color.gray : Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(email.isEmpty || isRequestingRecovery)
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .navigationTitle("Account Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .sheet(isPresented: $showQrScanner) {
            ProteanRecoveryView(authTokenProvider: { nil })
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }

    private var recoveryRequestedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 80))
                .foregroundStyle(.green)
                .padding(.top, 40)

            Text("Recovery Requested")
                .font(.title)
                .fontWeight(.bold)

            VStack(spacing: 12) {
                Text("Check your email for a verification link.")
                    .multilineTextAlignment(.center)

                Text("Once verified, your credential will be available for download after a 24-hour security delay.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            // Security notice
            VStack(alignment: .leading, spacing: 8) {
                Label("Why 24 hours?", systemImage: "lock.shield")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("This delay protects you if someone gains temporary access to your email. You'll be notified of the recovery request and can cancel it if you didn't initiate it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .padding(.horizontal)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        .navigationTitle("Recovery Requested")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private func requestRecovery() {
        guard !email.isEmpty else { return }

        isRequestingRecovery = true

        // In a real implementation, this would:
        // 1. Call the API to initiate recovery
        // 2. Send verification email
        // 3. Show the pending state

        Task {
            do {
                // Simulate API call
                try await Task.sleep(nanoseconds: 1_500_000_000)

                await MainActor.run {
                    isRequestingRecovery = false
                    recoveryRequested = true
                }
            } catch {
                await MainActor.run {
                    isRequestingRecovery = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}

// MARK: - Enrollment Container

struct EnrollmentContainerView: View {
    @StateObject private var viewModel = EnrollmentViewModel()
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            switch viewModel.state {
            case .initial, .scanningQR:
                QRScannerView { code in
                    Task {
                        await viewModel.handleScannedCode(code)
                    }
                }

            case .processingInvitation:
                processingView

            case .connectingToNats:
                connectingToNatsView

            case .requestingAttestation:
                requestingAttestationView

            case .attestationRequired, .attesting, .attestationComplete:
                AttestationView(viewModel: viewModel) {
                    // Attestation complete callback
                }

            case .settingPIN, .processingPIN:
                EnrollmentPINSetupView(viewModel: viewModel)

            case .waitingForVault:
                waitingForVaultView

            case .settingPassword, .processingPassword:
                PasswordSetupView(viewModel: viewModel)

            case .creatingCredential:
                creatingCredentialView

            case .finalizing:
                finalizingView

            case .settingUpNats:
                settingUpNatsView

            case .verifyingEnrollment:
                verifyingEnrollmentView

            case .complete(let userGuid):
                EnrollmentCompleteView(userGuid: userGuid) {
                    appState.refreshCredentialState()
                    // Start background sync after successful enrollment
                    VaultBackgroundRefresh.shared.onEnrollmentComplete()
                    dismiss()
                }

            case .error(let message, let retryable):
                errorView(message: message, retryable: retryable)
            }
        }
        .navigationTitle(viewModel.state.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!viewModel.state.canGoBack)
        .toolbar {
            if viewModel.state.canGoBack {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Processing View

    private var processingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .accessibilityIdentifier("enrollment.progressIndicator")

            Text("Processing invitation...")
                .font(.headline)
                .accessibilityIdentifier("enrollment.processingText")

            Text("Connecting to vault services")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("enrollment.processingView")
    }

    // MARK: - Finalizing View

    private var finalizingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Completing enrollment...")
                .font(.headline)

            Text("Setting up your secure credential")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Setting Up NATS View

    private var settingUpNatsView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Setting up messaging...")
                .font(.headline)

            Text("Configuring secure vault communication")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Connecting to NATS View

    private var connectingToNatsView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .accessibilityIdentifier("enrollment.connectingProgress")

            Text("Connecting to vault...")
                .font(.headline)
                .accessibilityIdentifier("enrollment.connectingText")

            Text("Establishing secure channel")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("enrollment.connectingToNatsView")
    }

    // MARK: - Requesting Attestation View

    private var requestingAttestationView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 50))
                .foregroundStyle(.blue)
                .accessibilityIdentifier("enrollment.attestationIcon")

            ProgressView()
                .scaleEffect(1.2)

            Text("Verifying enclave...")
                .font(.headline)
                .accessibilityIdentifier("enrollment.attestationText")

            Text("Validating secure environment")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("enrollment.requestingAttestationView")
    }

    // MARK: - Waiting for Vault View

    private var waitingForVaultView: some View {
        VStack(spacing: 20) {
            Image(systemName: "building.2")
                .font(.system(size: 50))
                .foregroundStyle(.blue)
                .accessibilityIdentifier("enrollment.vaultIcon")

            ProgressView()
                .scaleEffect(1.2)

            Text("Starting your vault...")
                .font(.headline)
                .accessibilityIdentifier("enrollment.waitingVaultText")

            Text("This may take a moment")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("enrollment.waitingForVaultView")
    }

    // MARK: - Creating Credential View

    private var creatingCredentialView: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 50))
                .foregroundStyle(.blue)
                .accessibilityIdentifier("enrollment.credentialIcon")

            ProgressView()
                .scaleEffect(1.2)

            Text("Creating credential...")
                .font(.headline)
                .accessibilityIdentifier("enrollment.creatingCredentialText")

            Text("Generating secure keys")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("enrollment.creatingCredentialView")
    }

    // MARK: - Verifying Enrollment View

    private var verifyingEnrollmentView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 50))
                .foregroundStyle(.green)
                .accessibilityIdentifier("enrollment.verifyIcon")

            ProgressView()
                .scaleEffect(1.2)

            Text("Verifying enrollment...")
                .font(.headline)
                .accessibilityIdentifier("enrollment.verifyingText")

            Text("Almost done")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("enrollment.verifyingEnrollmentView")
    }

    // MARK: - Error View

    private func errorView(message: String, retryable: Bool) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
                .accessibilityIdentifier("enrollment.errorIcon")

            Text("Enrollment Failed")
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityIdentifier("enrollment.errorTitle")

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier("enrollment.errorMessage")

            if retryable {
                Button("Try Again") {
                    viewModel.reset()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("enrollment.retryButton")
            }

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("enrollment.cancelButton")
        }
        .padding()
        .accessibilityIdentifier("enrollment.errorView")
    }
}

// MARK: - Manual Enrollment View

struct ManualEnrollmentView: View {
    @State private var invitationCode = ""
    @StateObject private var viewModel = EnrollmentViewModel()

    var body: some View {
        VStack(spacing: 24) {
            Text("Enter your invitation code")
                .font(.headline)
                .accessibilityIdentifier("manualEnrollment.instructionText")

            TextField("Invitation Code", text: $invitationCode)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal)
                .accessibilityIdentifier("manualEnrollment.codeTextField")

            Button("Continue") {
                Task {
                    await viewModel.handleScannedCode(invitationCode)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(invitationCode.isEmpty)
            .accessibilityIdentifier("manualEnrollment.continueButton")

            Spacer()
        }
        .padding(.top, 40)
        .navigationTitle("Enter Code")
        .accessibilityIdentifier("manualEnrollment.view")
    }
}

// MARK: - Authentication View

/// Entry point for authentication - offers biometric quick unlock or full auth
struct AuthenticationView: View {
    @EnvironmentObject var appState: AppState
    @State private var showFullAuth = false

    var body: some View {
        VStack(spacing: 24) {
            Image("VettIDLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("unlock.logo")

            Text("Unlock VettID")
                .font(.title)
                .fontWeight(.semibold)
                .accessibilityIdentifier("unlock.title")

            Text("Use Face ID for quick access or authenticate with your password")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier("unlock.subtitle")

            VStack(spacing: 12) {
                Button(action: {
                    attemptBiometricUnlock()
                }) {
                    Label("Unlock with Face ID", systemImage: "faceid")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("unlock.biometricButton")

                Button(action: {
                    showFullAuth = true
                }) {
                    Text("Use Password")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("unlock.passwordButton")
            }
            .padding(.horizontal)
        }
        .padding()
        .accessibilityIdentifier("unlockView")
        .onAppear {
            attemptBiometricUnlock()
        }
        .sheet(isPresented: $showFullAuth) {
            AuthenticationContainerView()
                .environmentObject(appState)
        }
    }

    private func attemptBiometricUnlock() {
        Task {
            let biometricService = BiometricAuthService()
            do {
                // authenticate() returns LAContext on success, throws on failure
                _ = try await biometricService.authenticate(reason: "Unlock your VettID vault")
                await MainActor.run {
                    appState.isAuthenticated = true
                }
            } catch {
                // Biometric failed, user can try password instead
            }
        }
    }
}

// MARK: - Main Tab View (Legacy - replaced by MainNavigationView)

// Using MainNavigationView from Features/Navigation/MainNavigationView.swift

// MARK: - Placeholder Views

struct CredentialsView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "key.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Credentials")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Credential management coming soon")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Credentials")
        }
    }
}

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    Label("Profile", systemImage: "person.circle")
                    Label("Security", systemImage: "lock.shield")
                }

                Section("App") {
                    Label("Notifications", systemImage: "bell")
                    Label("Appearance", systemImage: "paintbrush")
                }

                Section("About") {
                    Label("Help & Support", systemImage: "questionmark.circle")
                    Label("Privacy Policy", systemImage: "hand.raised")
                    Label("Version 1.0.0", systemImage: "info.circle")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Security Warning View

/// Displays security warnings when device integrity issues are detected
/// Shows on compromised devices (jailbroken, rooted, instrumented)
struct SecurityWarningView: View {
    let threats: [String]
    let onContinue: (() -> Void)?
    let onExit: (() -> Void)?

    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 24) {
            // Warning icon
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 64))
                .foregroundColor(.red)

            // Title
            Text("Security Warning")
                .font(.title)
                .fontWeight(.bold)

            // Main message
            Text("This device may be compromised. Using VettID on this device puts your credentials at risk.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            // Threat details (expandable)
            if !threats.isEmpty {
                DisclosureGroup("Detected Issues (\(threats.count))", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(threats, id: \.self) { threat in
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.caption)
                                Text(threat)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .padding()
                .background(Color(UIColor.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)
            }

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                if let onContinue = onContinue {
                    Button(action: onContinue) {
                        Text("Continue Anyway")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange)
                            .cornerRadius(12)
                    }

                    Text("Not recommended - your credentials may be exposed")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if let onExit = onExit {
                    Button(action: onExit) {
                        Text("Exit App")
                            .font(.headline)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(UIColor.systemGray6))
                            .cornerRadius(12)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .padding(.top, 48)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppState())
}
