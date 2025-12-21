import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var deepLinkHandler: DeepLinkHandler
    @StateObject private var lockService = AppLockService.shared
    @Environment(\.scenePhase) private var scenePhase

    // Deep link navigation state
    @State private var showEnrollmentFromDeepLink = false
    @State private var deepLinkEnrollToken: String?

    var body: some View {
        ZStack {
            // Main content
            Group {
                if !appState.hasCredential {
                    WelcomeView()
                } else if !appState.isAuthenticated {
                    AuthenticationView()
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
        case .active:
            lockService.appWillEnterForeground()
        case .inactive:
            break
        @unknown default:
            break
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

                // Title
                Text("Welcome to VettID")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                // Subtitle
                Text("Secure credential management\nfor your personal vault")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()

                // Primary action - QR scan
                NavigationLink(destination: EnrollmentContainerView()) {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // Secondary action - manual entry
                NavigationLink(destination: ManualEnrollmentView()) {
                    Text("Enter code manually")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Spacer()
                    .frame(height: 40)
            }
            .padding()
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

            case .attestationRequired, .attesting, .attestationComplete:
                AttestationView(viewModel: viewModel) {
                    // Attestation complete callback
                }

            case .settingPassword, .processingPassword:
                PasswordSetupView(viewModel: viewModel)

            case .finalizing:
                finalizingView

            case .settingUpNats:
                settingUpNatsView

            case .complete(let userGuid):
                EnrollmentCompleteView(userGuid: userGuid) {
                    appState.refreshCredentialState()
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

            Text("Processing invitation...")
                .font(.headline)

            Text("Connecting to vault services")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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

    // MARK: - Error View

    private func errorView(message: String, retryable: Bool) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            Text("Enrollment Failed")
                .font(.title2)
                .fontWeight(.bold)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if retryable {
                Button("Try Again") {
                    viewModel.reset()
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

// MARK: - Manual Enrollment View

struct ManualEnrollmentView: View {
    @State private var invitationCode = ""
    @StateObject private var viewModel = EnrollmentViewModel()
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Text("Enter your invitation code")
                .font(.headline)

            TextField("Invitation Code", text: $invitationCode)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding(.horizontal)

            Button("Continue") {
                Task {
                    await viewModel.handleScannedCode(invitationCode)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(invitationCode.isEmpty)

            Spacer()
        }
        .padding(.top, 40)
        .navigationTitle("Enter Code")
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

            Text("Unlock VettID")
                .font(.title)
                .fontWeight(.semibold)

            Text("Use Face ID for quick access or authenticate with your password")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button(action: {
                    attemptBiometricUnlock()
                }) {
                    Label("Unlock with Face ID", systemImage: "faceid")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: {
                    showFullAuth = true
                }) {
                    Text("Use Password")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal)
        }
        .padding()
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

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppState())
}
