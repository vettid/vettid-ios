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
    @Published var vaultStatus: VaultStatus?

    private let credentialStore = CredentialStore()

    init() {
        checkExistingCredential()
    }

    func checkExistingCredential() {
        hasCredential = credentialStore.hasStoredCredential()
    }
}

enum VaultStatus: Equatable {
    case pendingEnrollment
    case provisioning
    case running(instanceId: String)
    case stopped
    case terminated
}
