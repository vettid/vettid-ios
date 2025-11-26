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

struct WelcomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.blue)

                Text("Welcome to VettID")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Secure credential management\nfor your personal vault")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()

                NavigationLink(destination: EnrollmentView()) {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                NavigationLink(destination: ManualEnrollmentView()) {
                    Text("I have an enrollment link")
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

struct AuthenticationView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "faceid")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Authenticate")
                .font(.title)
                .fontWeight(.semibold)

            Button("Unlock with Face ID") {
                authenticate()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .onAppear {
            authenticate()
        }
    }

    private func authenticate() {
        // TODO: Implement biometric authentication
        Task {
            // Simulated for now
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                appState.isAuthenticated = true
            }
        }
    }
}

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

struct EnrollmentView: View {
    var body: some View {
        Text("QR Scanner - Coming Soon")
            .navigationTitle("Scan QR Code")
    }
}

struct ManualEnrollmentView: View {
    var body: some View {
        Text("Manual Enrollment - Coming Soon")
            .navigationTitle("Enter Code")
    }
}

struct VaultView: View {
    var body: some View {
        NavigationStack {
            Text("Vault Status - Coming Soon")
                .navigationTitle("My Vault")
        }
    }
}

struct CredentialsView: View {
    var body: some View {
        NavigationStack {
            Text("Credentials - Coming Soon")
                .navigationTitle("Credentials")
        }
    }
}

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Text("Settings - Coming Soon")
                .navigationTitle("Settings")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
