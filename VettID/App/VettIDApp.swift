import SwiftUI

@main
struct VettIDApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var isAuthenticated = false
    @Published var hasCredential = false
    @Published var currentUserGuid: String?
    @Published var vaultStatus: VaultStatus?

    private let credentialStore = CredentialStore()

    init() {
        checkExistingCredential()
    }

    func checkExistingCredential() {
        hasCredential = credentialStore.hasStoredCredential()
        if let credential = try? credentialStore.retrieveFirst() {
            currentUserGuid = credential.userGuid
            if let status = credential.vaultStatus {
                vaultStatus = parseVaultStatus(status)
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

    /// Lock the app - same as sign out for now
    func lock() {
        isAuthenticated = false
    }

    /// Full sign out - clears credentials (requires re-enrollment)
    func fullSignOut() {
        isAuthenticated = false
        hasCredential = false
        currentUserGuid = nil
        vaultStatus = nil
        // TODO: Clear keychain credentials
    }

    private func parseVaultStatus(_ status: String) -> VaultStatus {
        switch status.uppercased() {
        case "PENDING_ENROLLMENT":
            return .pendingEnrollment
        case "PROVISIONING":
            return .provisioning
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
}
