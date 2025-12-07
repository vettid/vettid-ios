import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if !appState.hasCredential {
                WelcomeView()
            } else if !appState.isAuthenticated {
                AuthenticationView()
            } else {
                MainTabView()
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
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.blue)

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
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

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
                let success = try await biometricService.authenticate(reason: "Unlock your VettID vault")
                if success {
                    await MainActor.run {
                        appState.isAuthenticated = true
                    }
                }
            } catch {
                // Biometric failed, user can try password instead
            }
        }
    }
}

// MARK: - Main Tab View

struct MainTabView: View {
    var body: some View {
        TabView {
            VaultView()
                .tabItem {
                    Label("Vault", systemImage: "building.columns.fill")
                }

            CredentialsView()
                .tabItem {
                    Label("Credentials", systemImage: "key.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
    }
}

// MARK: - Placeholder Views

struct VaultView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Your Vault")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Vault management coming soon")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("My Vault")
        }
    }
}

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
