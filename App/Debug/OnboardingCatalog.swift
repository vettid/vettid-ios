#if DEBUG
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDOnboardingUI
import VettIDUI

/// Debug only: every onboarding screen state with sample data, for the screen catalog and the previews (vettid-
/// android's screen catalog entries for onboarding). The samples are fixed states with actions that do nothing; the
/// camera is a placeholder. In the app rather than in VettIDOnboardingUI: a package is built without `DEBUG` in the
/// DevStack configuration. The release check refuses its strings.
enum OnboardingCatalog {
    struct Entry: Identifiable, Sendable {
        let id: String
        let title: String
        let state: OnboardingState
    }

    static let entries: [Entry] = {
        var all: [Entry] = []
        func add(_ id: String, _ title: String, _ step: OnboardingStep, _ edit: (inout OnboardingState) -> Void = { _ in }) {
            var s = OnboardingState(step: step)
            edit(&s)
            all.append(Entry(id: id, title: title, state: s))
        }
        add("welcome", "Welcome", .welcome)
        add("welcome_dev", "Welcome, development hint", .welcome) { $0.devHint = "Dev stack: codes come from the local portal." }
        add("scan", "Scan the setup code", .setupScan)
        add("scan_redeeming", "Scan: checking the code", .setupScan) { $0.busy = true }
        add("scan_not_code", "Scan: not a setup code", .setupScan) { $0.scanRefusal = .notACode }
        add("scan_recovery", "Scan: a recovery code", .setupScan) { $0.scanRefusal = .recoveryCode }
        add("scan_other_env", "Scan: another environment", .setupScan) {
            $0.scanRefusal = .otherEnvironment
            $0.otherApi = "https://account.example.org"
        }
        add("scan_invalid", "Scan: the code did not work", .setupScan) { $0.error = .setupCodeInvalid }
        add("type", "Type the code", .setupType)
        add("type_filled", "Type: filled in", .setupType) {
            $0.email = "sam@example.org"
            $0.codeInput = "K7QM-4XRP"
        }
        add("type_invalid", "Type: malformed email and code", .setupType) {
            $0.email = "sam@"
            $0.codeInput = "K7QM-4XR0"
            $0.emailInvalid = true
            $0.codeInvalid = true
        }
        add("type_refused", "Type: the code did not work", .setupType) {
            $0.email = "sam@example.org"
            $0.codeInput = "K7QM-4XRP"
            $0.error = .setupCodeInvalid
        }
        add("confirm", "Is this your account?", .confirmAccount) { $0.emailHint = "m***@example.com" }
        add("elsewhere", "The account already has a vault", .vaultElsewhere)
        add("pin", "Choose the PIN", .pinCreate)
        add("pin_problem", "PIN: a simple pattern", .pinCreate) { $0.pinProblem = .sequence }
        add("pin_confirm", "Confirm the PIN", .pinConfirm)
        add("pin_mismatch", "Confirm: the PINs differ", .pinConfirm) { $0.pinMismatch = true }
        add("password", "Credential password", .password)
        add("password_guessable", "Password: guessable", .password) { s in
            s.password = "123456789123"
            s.passwordRule = .guessable
        }
        add("password_ok", "Password: strong enough, mismatch", .password) { s in
            s.password = "correct horse battery staple"
            s.passwordConfirm = "correct horse battery stapel"
            s.passwordRule = .ok
            s.passwordMismatch = true
        }
        add("password_refused", "Password: refused by the vault", .password) { s in
            s.password = "correct horse battery staple"
            s.passwordConfirm = s.password
            s.passwordRule = .vaultRefused
            s.passwordRefused = true
            s.credentialOnly = true
        }
        add("password_pin", "Password with the PIN (release R)", .password) { s in
            s.askPin = true
            s.credentialOnly = true
        }
        add("backup", "Backup on", .backup)
        add("backup_off", "Backup off", .backup) { $0.backup = false }
        add("backup_off_ack", "Backup off, acknowledged", .backup) { s in
            s.backup = false
            s.backupOffAcknowledged = true
        }
        add("progress", "Setting up", .progress) { s in
            s.busy = true
            s.progress = [
                ProgressEntry(.enroll, .done), ProgressEntry(.waitForVault, .done), ProgressEntry(.handshake, .active),
                ProgressEntry(.createCredential, .pending), ProgressEntry(.backup, .pending), ProgressEntry(.confirm, .pending),
            ]
        }
        add("progress_failed", "Setup stopped", .progress) { s in
            s.error = .noResponse
            s.progress = [
                ProgressEntry(.enroll, .done), ProgressEntry(.waitForVault, .done), ProgressEntry(.handshake, .done),
                ProgressEntry(.createCredential, .failed), ProgressEntry(.backup, .pending), ProgressEntry(.confirm, .pending),
            ]
        }
        add("progress_expired", "Setup stopped: the key expired", .progress) { s in
            s.error = .unauthorized
            s.progress = [ProgressEntry(.enroll, .failed)] + [EnrollStep.waitForVault, .handshake, .createCredential, .backup, .confirm]
                .map { ProgressEntry($0, .pending) }
        }
        add("done", "Your vault is ready", .done)
        add("done_failed", "Ready, but leaving failed", .done) { $0.error = .network }
        return all
    }()

    /// The screen for [entry], with actions that do nothing and a placeholder for the camera.
    @MainActor
    static func screen(_ entry: Entry, actions: any OnboardingActions = NoOnboardingActions()) -> some View {
        OnboardingContent(
            state: entry.state, actions: actions, routes: .pending, onOpenAccountSite: {}, camera: AnyView(CameraPlaceholder())
        )
    }
}

/// Stands in for the camera preview.
private struct CameraPlaceholder: View {
    @Environment(\.vettIDColors) private var colors

    var body: some View {
        ZStack {
            colors.surfaceContainerHigh.color
            VettIDSymbol.qrCode.image.font(.system(size: 64)).foregroundStyle(colors.onSurfaceVariant)
        }
    }
}

#Preview("Onboarding states") {
    TabView {
        ForEach(OnboardingCatalog.entries) { entry in
            OnboardingCatalog.screen(entry).tabItem { Text(verbatim: entry.title) }
        }
    }
    .tabViewStyle(.page)
    .vettIDTheme(.dark)
}

#Preview("Welcome") { OnboardingCatalog.screen(OnboardingCatalog.entries[0]).vettIDTheme() }
#endif
