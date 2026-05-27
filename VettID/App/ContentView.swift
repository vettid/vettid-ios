import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var deepLinkHandler: DeepLinkHandler
    @StateObject private var lockService = AppLockService.shared
    /// Phase 5.4 — owns the queue of incoming peer location-request
    /// pings so the alert surfaces regardless of which screen the user
    /// is on. Wires up the OwnerSpaceClient subscription after warm.
    @StateObject private var peerLocationPrompt = PeerLocationRequestPromptViewModel()
    /// Phase 4.3 — calling singleton observed for full-screen cover
    /// routing (Outgoing / Incoming / Active). Configured by AppState
    /// after warmVault so the wire is live when an event arrives.
    @ObservedObject private var callCoordinator = CallCoordinator.shared
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
            // Main content. Android-parity routing: once the device
            // holds a credential, the only unlock surface is the PIN
            // entry / vault warm screen. The old `!isAuthenticated →
            // AuthenticationView` branch dropped the user onto the
            // "Unlock VettID / Use Password" screen post-relaunch and
            // pushed them through a password sheet that surfaced
            // `AuthenticationContainerView`'s "no keys available — re-
            // enrollment required" error. iOS now treats a successful
            // PIN warm as the authentication, the same way Android
            // does.
            Group {
                if !appState.hasCredential {
                    WelcomeView()
                } else if appState.needsVaultWarming || !appState.isAuthenticated {
                    // Vault is cold or session not yet established —
                    // PIN unlock is the authentication.
                    VaultWarmingView {
                        appState.isAuthenticated = true
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
        .onChange(of: appState.isAuthenticated) { _ in
            // After warm, AppState builds the OwnerSpaceClient. Attach
            // the prompt VM once available so peer location-request
            // pings have somewhere to land.
            if let osc = appState.ownerSpaceClient {
                peerLocationPrompt.attach(ownerSpaceClient: osc) { _ in nil }
            }
        }
        .sheet(isPresented: $showEnrollmentFromDeepLink) {
            if let token = deepLinkEnrollToken {
                DeepLinkEnrollmentView(token: token)
                    .environmentObject(appState)
            }
        }
        // Phase 4.3 — call screens cover the app whenever there's an
        // active call (outbound dialing, inbound ringing, or in-call).
        // Coordinator's currentCall identity drives the binding so
        // the cover dismisses cleanly when the call ends.
        .fullScreenCover(item: Binding<CurrentCall?>(
            get: { callCoordinator.currentCall },
            set: { _ in /* dismissal is driven by callState, not by user gesture */ }
        )) { call in
            currentCallScreen(for: call)
        }
        // Phase 5.4 — peer location-request prompt. Surfaces at app
        // root so a ping that arrives while the user is on the feed
        // (or any other screen) still produces a visible dialog.
        .alert(
            "Location requested",
            isPresented: Binding(
                get: { peerLocationPrompt.pendingRequest != nil },
                set: { newValue in if !newValue { peerLocationPrompt.dismiss() } }
            ),
            presenting: peerLocationPrompt.pendingRequest
        ) { request in
            Button("Send") {
                Task { await peerLocationPrompt.fulfill() }
            }
            .disabled(peerLocationPrompt.isSending)
            Button("Ignore", role: .cancel) {
                peerLocationPrompt.dismiss()
            }
        } message: { request in
            Text("\(request.peerLabel ?? "A connection") asked for your current location. Sending shares it once — they won't see your future location unless you turn on sharing.")
        }
        // Area B — per-op desktop approval. A new pending request flips
        // appState.pendingDeviceApproval to non-null; full-screen cover
        // pops the user straight onto DeviceApprovalView regardless of
        // which screen they were on. Mirrors Android's
        // LaunchedEffect(pendingDeviceApproval) → DeviceApproval route.
        // Gated on isAuthenticated so a request that lands while the
        // app is locked doesn't pre-empt the PIN screen — it'll
        // resurface from fetchPendingDeviceApprovals after unlock.
        .fullScreenCover(item: Binding<DeviceApprovalRequest?>(
            get: { appState.isAuthenticated ? appState.pendingDeviceApproval : nil },
            set: { newValue in if newValue == nil { appState.clearPendingDeviceApproval() } }
        )) { request in
            NavigationStack {
                DeviceApprovalView(
                    ownerSpaceClient: appState.ownerSpaceClient,
                    approvalRequest: request
                )
            }
        }
        // Area G — Stage-2 agent pairing. When the vault publishes
        // forApp.agent.pending-authorization, AppState bridges it to
        // pendingAgentAuth; we full-screen-cover AuthorizeAgentView
        // so the owner can pick scope/duration and Approve regardless
        // of which screen they were on. Mirrors Android's
        // LaunchedEffect(agentPendingAuth) → Screen.AgentAuthorize
        // route in VettIDApp.kt (commit 830ba5f).
        .fullScreenCover(item: Binding<AgentPendingAuthNotification?>(
            get: { appState.isAuthenticated ? appState.pendingAgentAuth : nil },
            set: { newValue in if newValue == nil { appState.clearPendingAgentAuth() } }
        )) { notification in
            NavigationStack {
                AuthorizeAgentView(
                    connectionId: notification.connectionId,
                    ownerSpaceClient: appState.ownerSpaceClient,
                    onAuthorized: { appState.clearPendingAgentAuth() },
                    onDeny: { appState.clearPendingAgentAuth() }
                )
            }
        }
        // Area H — agent-initiated LEASH mint awaiting owner approval.
        // Mirrors the agentPendingAuth pattern above: the vault
        // pushes forApp.agent.leash-mint-pending, AppState bridges to
        // pendingLeashMint, root-level cover pops LeashApprovalView
        // regardless of which screen the user was on.
        .fullScreenCover(item: Binding<AgentLeashMintPendingNotification?>(
            get: { appState.isAuthenticated ? appState.pendingLeashMint : nil },
            set: { newValue in if newValue == nil { appState.clearPendingLeashMint() } }
        )) { notification in
            NavigationStack {
                LeashApprovalView(
                    requestId: notification.requestId,
                    ownerSpaceClient: appState.ownerSpaceClient,
                    onDone: { appState.clearPendingLeashMint() }
                )
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

    // MARK: - Call screen routing (Phase 4.3)

    @ViewBuilder
    private func currentCallScreen(for call: CurrentCall) -> some View {
        let state = callCoordinator.callState
        if state == .connected || state == .reconnecting {
            ActiveCallView(coordinator: callCoordinator, onEnded: { })
        } else if state == .failed {
            // Brief failure surface — the coordinator clears
            // currentCall shortly, dismissing the cover.
            CallFailedView(coordinator: callCoordinator)
        } else if state == .idle {
            EmptyView()
        } else if call.direction == .incoming {
            IncomingCallView(
                coordinator: callCoordinator,
                onAnswered: { /* state will advance into .connected */ },
                onDeclined: { /* coordinator clears currentCall */ }
            )
        } else {
            // Outgoing in any pre-connected state — show the dialing UI.
            OutgoingCallView(coordinator: callCoordinator, onCancel: { })
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

                // Subtitle — matches Android welcome screen (VettIDApp.kt).
                Text("Control your data.\nSecure your keys.\nOwn your future.")
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
    /// Phase 5.8 — flips on EnrollmentCompleteView's Continue tap so
    /// the .complete case renders the post-enrollment next-steps panel.
    @State private var showNextSteps = false
    /// If non-nil, run `handleScannedCode` with this on appear so the
    /// manual-entry screen can hand control to the wizard with the
    /// portal short code already in flight (instead of showing the
    /// QR scanner first).
    let seededCode: String?

    init(seededCode: String? = nil) {
        self.seededCode = seededCode
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator (hidden on initial/scanning and completion states)
            if shouldShowStepIndicator {
                EnrollmentStepIndicator(currentPhase: viewModel.state.wizardPhase)
            }

            // Main content
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

                case .confirmIdentity(let identity):
                    ConfirmIdentityView(
                        firstName: identity.firstName,
                        lastName: identity.lastName,
                        email: identity.email,
                        photoData: $viewModel.profilePhotoData,
                        onConfirm: { viewModel.confirmIdentity() },
                        onReject: { viewModel.rejectIdentity() }
                    )

                case .identityRejected:
                    identityRejectedView

                case .settingPIN, .processingPIN:
                    EnrollmentPINSetupView(viewModel: viewModel)

                case .waitingForVault:
                    waitingForVaultView

                case .settingPassword, .processingPassword:
                    PasswordSetupView(viewModel: viewModel)

                case .creatingCredential:
                    creatingCredentialView

                case .confirmProfile:
                    ConfirmProfileView(
                        displayName: viewModel.scannedCode ?? "User",
                        email: nil,
                        onConfirm: {
                            Task { await viewModel.confirmProfile() }
                        },
                        onSkip: { viewModel.skipProfile() }
                    )

                case .finalizing:
                    finalizingView

                case .settingUpNats:
                    settingUpNatsView

                case .verifyingEnrollment:
                    verifyingEnrollmentView

                // ===== Android-parity VERIFY_CREDENTIAL =====
                case .verifyingCredentialEntry, .processingVerify:
                    VerifyCredentialView(viewModel: viewModel)

                case .verifySuccess:
                    VerifySuccessView()

                // ===== Android-parity PERMISSIONS =====
                case .requestingPermissions:
                    RequestPermissionsView(viewModel: viewModel)

                case .complete(let userGuid):
                    // Drop the legacy `PostEnrollmentNextStepsView` (the
                    // "offer to add data" screen) — Android's wizard
                    // lands on the success screen and then straight on
                    // the main app. Continue here marks the user as
                    // authenticated so the parent ContentView routes to
                    // `MainNavigationView` instead of bouncing through
                    // the password-prompt `AuthenticationView`.
                    EnrollmentCompleteView(userGuid: userGuid) {
                        appState.markEnrolledAndAuthenticated(userGuid: userGuid)
                        VaultBackgroundRefresh.shared.onEnrollmentComplete()
                        dismiss()
                    }

                case .error(let message, let retryable):
                    errorView(message: message, retryable: retryable)
                }
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
        // Manual-entry handoff: when the parent pushes us with a
        // pre-typed portal code, kick off the same path the QR
        // scanner uses so the wizard transitions through progress
        // and error states normally.
        .task(id: seededCode ?? "") {
            if let code = seededCode, !code.isEmpty, case .initial = viewModel.state {
                await viewModel.handleScannedCode(code)
            }
        }
    }

    private var shouldShowStepIndicator: Bool {
        switch viewModel.state {
        case .initial, .scanningQR, .complete, .error:
            return false
        default:
            return true
        }
    }

    // MARK: - Identity Rejected View

    private var identityRejectedView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer().frame(height: 32)

                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.red)

                    VStack(spacing: 8) {
                        Text("Identity Mismatch Reported")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("This enrollment has been cancelled. A mismatch report has been sent for investigation.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
            }

            Button {
                viewModel.reset()
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Transient Progress Views
    //
    // All "doing background work" wizard states share the same layout:
    // a tall centered card with an icon, headline, body subtitle, and
    // a small spinner — modeled on Android's transient phase rows.
    // `transientProgressView` is the single source of truth so they
    // stay visually consistent and easy to retune.

    private func transientProgressView(
        icon: String,
        title: String,
        subtitle: String,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.bold)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            ProgressView()
                .controlSize(.regular)
                .padding(.top, 8)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    private var processingView: some View {
        transientProgressView(
            icon: "qrcode.viewfinder",
            title: "Processing invitation",
            subtitle: "Connecting to vault services…",
            accessibilityIdentifier: "enrollment.processingView"
        )
    }

    private var finalizingView: some View {
        transientProgressView(
            icon: "checkmark.shield",
            title: "Completing enrollment",
            subtitle: "Setting up your secure credential…"
        )
    }

    private var settingUpNatsView: some View {
        transientProgressView(
            icon: "antenna.radiowaves.left.and.right",
            title: "Setting up messaging",
            subtitle: "Configuring secure vault communication…"
        )
    }

    private var connectingToNatsView: some View {
        transientProgressView(
            icon: "antenna.radiowaves.left.and.right",
            title: "Connecting to vault",
            subtitle: "Establishing secure channel…",
            accessibilityIdentifier: "enrollment.connectingToNatsView"
        )
    }

    private var requestingAttestationView: some View {
        transientProgressView(
            icon: "checkmark.shield",
            title: "Verifying enclave",
            subtitle: "Validating secure environment…",
            accessibilityIdentifier: "enrollment.requestingAttestationView"
        )
    }

    private var waitingForVaultView: some View {
        transientProgressView(
            icon: "building.2.fill",
            title: "Starting your vault",
            subtitle: "This may take a moment…",
            accessibilityIdentifier: "enrollment.waitingForVaultView"
        )
    }

    private var creatingCredentialView: some View {
        transientProgressView(
            icon: "key.fill",
            title: "Creating credential",
            subtitle: "Generating secure keys…",
            accessibilityIdentifier: "enrollment.creatingCredentialView"
        )
    }

    private var verifyingEnrollmentView: some View {
        transientProgressView(
            icon: "checkmark.circle",
            title: "Verifying enrollment",
            subtitle: "Almost done…",
            accessibilityIdentifier: "enrollment.verifyingEnrollmentView"
        )
    }

    // MARK: - Error View

    private func errorView(message: String, retryable: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer().frame(height: 24)

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("enrollment.errorIcon")

                    Text("Enrollment Failed")
                        .font(.title2)
                        .fontWeight(.bold)
                        .accessibilityIdentifier("enrollment.errorTitle")

                    // Surface the underlying detail in a quiet card —
                    // matches Android's errorContainer treatment so the
                    // actual error message stays visible/copyable rather
                    // than being a tiny grey subtitle.
                    if !message.isEmpty {
                        Text(message)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color.red.opacity(0.08))
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("enrollment.errorMessage")
                    }
                }
                .padding(.horizontal, 24)
            }

            VStack(spacing: 8) {
                if retryable {
                    Button {
                        viewModel.reset()
                    } label: {
                        Text("Try Again")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("enrollment.retryButton")
                }

                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .accessibilityIdentifier("enrollment.cancelButton")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .accessibilityIdentifier("enrollment.errorView")
    }
}

// MARK: - Manual Enrollment View

struct ManualEnrollmentView: View {
    /// RAW alphanumeric storage — e.g. "ABCD1234". The dash is never
    /// stored; it's reintroduced only for display (via the binding's
    /// `get`) and again on submit (canonical "XXXX-XXXX"). Same pattern
    /// as Android's StartPhaseContent + VisualTransformation, which we
    /// adopted after a String-with-dash storage there pinned the IME in
    /// caps-lock by clobbering the composing region every char.
    @State private var invitationCode = ""
    @State private var submittedCode: String? = nil
    @FocusState private var fieldFocused: Bool

    /// Display-side binding: dash injected purely for rendering.
    /// • get → "ABCD-1234" once there's a 5th char, "ABCD" before that
    /// • set → strip dash + any non-alphanumeric, uppercase, cap at 8
    private var formattedCodeBinding: Binding<String> {
        Binding(
            get: {
                if invitationCode.count > 4 {
                    return "\(invitationCode.prefix(4))-\(invitationCode.dropFirst(4))"
                }
                return invitationCode
            },
            set: { displayed in
                let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
                let cleaned = displayed.uppercased().filter { allowed.contains($0) }
                invitationCode = String(cleaned.prefix(8))
            }
        )
    }

    /// True once the user has typed all 8 alphanumerics (raw storage,
    /// so the count is on the raw 8 chars — no dash).
    private var isCodeComplete: Bool {
        invitationCode.count == 8
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 16)

                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text("Enter Enrollment Code")
                            .font(.title2)
                            .fontWeight(.bold)
                            .accessibilityIdentifier("manualEnrollment.instructionText")

                        Text("Enter the 8-character code from your VettID web portal.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }

                    TextField("ABCD-1234", text: formattedCodeBinding)
                        .font(.system(.title2, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: 280)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.separator), lineWidth: 1)
                        )
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .accessibilityIdentifier("manualEnrollment.codeTextField")
                        .onSubmit { submit() }
                }
                .padding(.horizontal, 24)
            }

            VStack(spacing: 12) {
                Button(action: submit) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isCodeComplete)
                .accessibilityIdentifier("manualEnrollment.continueButton")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Enter Code")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { fieldFocused = true }
        .accessibilityIdentifier("manualEnrollment.view")
        .navigationDestination(isPresented: Binding(
            get: { submittedCode != nil },
            set: { newValue in if !newValue { submittedCode = nil } }
        )) {
            if let code = submittedCode {
                EnrollmentContainerView(seededCode: code)
            }
        }
    }

    private func submit() {
        guard isCodeComplete else { return }
        fieldFocused = false
        // Storage is raw alphanumeric; the resolver and downstream API
        // both expect canonical "XXXX-XXXX". Format here, at the
        // hand-off, exactly mirroring Android's
        // EnrollmentWizardViewModel.submitManualInviteCode.
        let canonical = "\(invitationCode.prefix(4))-\(invitationCode.dropFirst(4))"
        // Push the wizard with this code pre-seeded so all progress
        // and error states render through EnrollmentContainerView.
        submittedCode = canonical
    }
}

// MARK: - Authentication View

/// Entry point for authentication - offers biometric quick unlock or full auth
struct AuthenticationView: View {
    @EnvironmentObject var appState: AppState
    @State private var showFullAuth = false
    @State private var showResetConfirm = false

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

            Text("Enter your password to authenticate.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier("unlock.subtitle")

            VStack(spacing: 12) {
                Button(action: {
                    showFullAuth = true
                }) {
                    Text("Use Password")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("unlock.passwordButton")

                // Escape hatch — if the credential on this device
                // belongs to a previous install / test account, this
                // wipes the local keychain + UserDefaults state and
                // returns the user to the enrollment Welcome screen.
                Button(role: .destructive, action: {
                    showResetConfirm = true
                }) {
                    Text("Start Over")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("unlock.startOverButton")
            }
            .padding(.horizontal)
        }
        .padding()
        .accessibilityIdentifier("unlockView")
        .sheet(isPresented: $showFullAuth) {
            AuthenticationContainerView()
                .environmentObject(appState)
        }
        .alert("Start over with a new enrollment?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Start Over", role: .destructive) {
                appState.fullSignOut()
            }
        } message: {
            Text("This clears the credential stored on this device. You'll go back to the welcome screen and can enroll a new identity. The vault on the server is not affected.")
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
