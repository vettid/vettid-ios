import Combine
import SwiftUI
import UIKit
import VettIDAltChan
import VettIDData
import VettIDOnboarding
import VettIDOnboardingUI
import VettIDSettings
import VettIDShell
import VettIDShellUI
import VettIDUI

@main
struct VettIDApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var themeMode: ThemeMode = Self.initialThemeMode
    /// "Allow screenshots" (ID10): on from the start only in the development builds, whose screens are screenshotted.
    @State private var screenshots = ScreenshotAllowance(onByDefault: AppEnvironment.current.kind.screenshotsByDefault)

    private static var initialThemeMode: ThemeMode {
        #if DEBUG
        // Debug builds: `-vettid.theme dark|light` at launch (screenshots).
        if let mode = UserDefaults.standard.string(forKey: "vettid.theme").flatMap(ThemeMode.init(rawValue:)) {
            return mode
        }
        #endif
        return .system
    }

    var body: some Scene {
        WindowGroup {
            RootView(environment: .current, composition: .shared, themeMode: $themeMode)
                .vettIDTheme(themeMode)
                .environment(screenshots)
                .privacyShield()
        }
    }
}

/// The root: onboarding while nothing is set up or setup is under way (IOS-PLAN §8 I1.6), the unlock, the owner check and
/// the stuck screens (I1.7), the app's shell (I1.8), all under the app lock (ID17). Debug builds can open the debug catalog
/// from it.
struct RootView: View {
    let environment: AppEnvironment
    let composition: AppComposition
    @Binding var themeMode: ThemeMode
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        AppLockGate(lock: composition.appLock, themeMode: themeMode) {
            #if DEBUG
            DebugCatalog(themeMode: $themeMode) {
                AppRoot(environment: environment, vault: composition.vault, inbox: composition.inbox, appLock: composition.appLock)
            }
            #else
            AppRoot(environment: environment, vault: composition.vault, inbox: composition.inbox, appLock: composition.appLock)
            #endif
        }
        // The app lock's settings could not be read at launch (the iPhone not unlocked since it started): read again.
        .onChange(of: scenePhase) { _, now in if now == .active { composition.startAppLock() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            composition.startAppLock()
        }
    }
}

/// Follows the vault manager's phase (vettid-android `VettIdApp`'s root): the phase is read at start; a setup link the
/// app was opened with goes to the onboarding flow, which redeems it only while nothing is set up.
struct AppRoot: View {
    let environment: AppEnvironment
    let vault: VaultManager
    let inbox: SetupLinkInbox
    let appLock: AppLock
    /// Where the member is in the open app, kept while the check past the deadline takes the shell's place.
    @State private var shell: ShellModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    init(environment: AppEnvironment, vault: VaultManager, inbox: SetupLinkInbox, appLock: AppLock) {
        self.environment = environment
        self.vault = vault
        self.inbox = inbox
        self.appLock = appLock
        _shell = State(initialValue: ShellModel(account: vault, vault: vault, ownerChecks: vault.ownerChecks))
    }

    var body: some View {
        content
            .task { try? await vault.refresh() }
            // A start before the first unlock (or while the iPhone was locked) read nothing: read again once the app is
            // active and protected data is available (IOS-PLAN §6.1, §6.3).
            .onChange(of: scenePhase) { _, now in
                switch now {
                case .active:
                    vault.onForeground()
                    retryRefresh()
                case .background:
                    leaveForeground()
                default:
                    break
                }
            }
            .onReceive(Self.protectedDataAvailable) { _ in
                // What could not be read before the first unlock (the owner check kept on the phone) is read now.
                vault.reloadLocalState()
                retryRefresh()
            }
            // A lock (or anything that leaves the open app) starts the next open afresh, as vettid-android's new shell does.
            .onChange(of: vault.phase) { _, now in if now != .unlocked { shell.reset() } }
            .onOpenURL { url in
                if SetupCodes.isSetupLink(url.absoluteString) { inbox.offer(url.absoluteString) }
            }
    }

    private static var protectedDataAvailable: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
    }

    /// Whether [phase] is a start that could not read this phone's state yet.
    static func readsAgain(_ phase: AppPhase) -> Bool {
        switch phase {
        case .starting, .unreachable(.phoneLocked, _): true
        default: false
        }
    }

    private func retryRefresh() {
        guard Self.readsAgain(vault.phase) else { return }
        Task { try? await vault.refresh() }
    }

    /// IOS-PLAN §6.6: what is in flight (a lock's first attempt, the outbox) is finished in a background task, within the
    /// time iOS gives it, then the collection stops (not when the app came back meanwhile). At the task's expiration the
    /// work is cancelled and the task ended. Nothing assumes it ran longer.
    private func leaveForeground() {
        let app = UIApplication.shared
        let background = BackgroundTask()
        let remaining = app.backgroundTimeRemaining
        // A margin before iOS's own end, and never more than half a minute (chosen; not in the spec).
        let seconds = remaining.isFinite ? min(max(remaining - 5, 1), 25) : 25
        let work = Task { @MainActor in
            await vault.onBackground(budget: .seconds(seconds))
            background.end(app)
        }
        background.id = app.beginBackgroundTask(withName: "vault-background") {
            MainActor.assumeIsolated {
                work.cancel()
                background.end(app)
            }
        }
    }

    private func openPortal() {
        if let url = URL(string: environment.apiOrigin) { openURL(url) }
    }

    @ViewBuilder private var content: some View {
        switch vault.phase {
        case .signedOut, .setup:
            OnboardingFlow(account: vault, vault: vault, inbox: inbox, routes: .pending) { openPortal() }
        case .starting:
            StartingScreen()
        case .unreachable:
            UnreachableFlow(account: vault) { openPortal() }
        case .locked:
            UnlockFlow(vault: vault, account: vault, ownerCheck: vault.ownerChecks) { openPortal() }
        case .unlocked:
            // The check past the deadline closes whatever the shell had open (the drawer, the sheet, an asked check), so
            // that nothing of it comes back for a moment afterwards.
            OwnerCheckGateView(vault: vault, onGated: { shell.shown() }) { gate, now in
                AppShell(
                    account: vault, vault: vault, ownerChecks: vault.ownerChecks, appLock: appLock, model: shell, gate: gate, now: now,
                    version: .of(Bundle.main.infoDictionary ?? [:]), installedFrom: InstalledFromBuild.current,
                    promptReason: AppLockTexts.reason
                ) { openPortal() }
            }
        }
    }
}

/// The daily owner check before any other use of the open app (VAULT-MESSAGING §3.6.5): past the deadline (re-read as
/// time passes, so that the deadline gates on its own) or after an unlock that cancelled a recovery whose check did not
/// pass, the check screen takes the shell's place (so that nothing of the vault under it is visible or reachable, and the
/// shell's sheets and dialogs close), never dismissible; otherwise [content], with the owner check at that moment for the
/// shell's banners (the early warning, the hold-off indicator, the notices, the presence notice). Where the member was
/// is kept above it (``ShellModel``). Mirrors vettid-android `OwnerCheckGate`.
struct OwnerCheckGateView<Content: View>: View {
    let vault: VaultManager
    /// The check took the shell's place.
    var onGated: @MainActor () -> Void = {}
    @ViewBuilder let content: (OwnerCheckGate, Date) -> Content
    /// The check screen was opened and is not done yet: it stays until the member goes on, so that a check that passed
    /// with the presence not recorded shows its notice (VAULT-MESSAGING §11.14.5), as vettid-android's route does until `onDone`.
    @State private var checking = false

    /// How often the deadline is compared with the clock (vettid-android: 15 s).
    static var tick: TimeInterval { 15 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.tick)) { context in
            let checks = vault.ownerChecks
            let gate = OwnerCheckGate.of(
                checks.ownerCheck, now: context.date, notices: checks.notices, presenceUnrecorded: checks.presenceUnrecorded
            )
            if checking || gate.gated || checks.checkAfterCancel {
                OwnerCheckFlow(mode: .gated, repo: checks, vault: vault) {
                    checking = false
                    checks.consumeCheckAfterCancel()
                }
                .onAppear {
                    checking = true
                    onGated()
                }
            } else {
                content(gate, context.date)
            }
        }
    }
}

/// One background task's identifier, ended once.
@MainActor
final class BackgroundTask {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end(_ app: UIApplication) {
        guard id != .invalid else { return }
        app.endBackgroundTask(id)
        id = .invalid
    }
}
