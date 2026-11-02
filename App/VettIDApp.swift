import Combine
import SwiftUI
import UIKit
import VettIDAltChan
import VettIDData
import VettIDOnboarding
import VettIDOnboardingUI
import VettIDSettings
import VettIDSettingsUI
import VettIDShell
import VettIDShellUI
import VettIDUI

@main
struct VettIDApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Settings → App → Theme: stored on this phone, applied everywhere at once.
    @State private var theme = ThemeSetting(launchOverride: Self.launchTheme)
    /// "Allow screenshots" (ID10): on from the start only in the development builds, whose screens are screenshotted.
    @State private var screenshots = ScreenshotAllowance(onByDefault: AppEnvironment.current.kind.screenshotsByDefault)

    /// Debug builds: `-vettid.theme dark|light` at launch (screenshots), shown but not stored.
    private static var launchTheme: ThemePreference? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "vettid.theme").flatMap(ThemePreference.init(rawValue:))
        #else
        nil
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(environment: .current, composition: .shared, themeMode: themeMode)
                .vettIDTheme(theme.theme.mode)
                .environment(screenshots)
                .environment(theme)
                .privacyShield()
        }
    }

    /// The debug gallery's theme chips change what is shown, never the member's stored choice.
    private var themeMode: Binding<ThemeMode> {
        let theme = theme
        return Binding(get: { theme.theme.mode }, set: { theme.show(ThemePreference($0)) })
    }
}

/// vettid-android `MainActivity`'s `toMode` and `toPreference`: the stored choice and the theme it applies.
extension ThemePreference {
    var mode: ThemeMode {
        switch self {
        case .system: .system
        case .light: .light
        case .dark: .dark
        }
    }

    init(_ mode: ThemeMode) {
        switch mode {
        case .system: self = .system
        case .light: self = .light
        case .dark: self = .dark
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
            DebugCatalog(themeMode: $themeMode) { appRoot }
            #else
            appRoot
            #endif
        }
        // The app lock's settings could not be read at launch (the iPhone not unlocked since it started): read again.
        .onChange(of: scenePhase) { _, now in if now == .active { composition.startAppLock() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            composition.startAppLock()
        }
    }

    private var appRoot: some View {
        AppRoot(
            environment: environment, vault: composition.vault, inbox: composition.inbox, canaryInbox: composition.canaryInbox,
            appLock: composition.appLock, releaseNotes: composition.releaseNotes, releaseInbox: composition.releaseInbox,
            inviteInbox: composition.inviteInbox
        )
    }
}

/// Follows the vault manager's phase (vettid-android `VettIdApp`'s root): the phase is read at start; a setup link the
/// app was opened with goes to the onboarding flow, which redeems it only while nothing is set up.
struct AppRoot: View {
    let environment: AppEnvironment
    let vault: VaultManager
    let inbox: SetupLinkInbox
    let canaryInbox: CanaryManifestInbox
    let appLock: AppLock
    /// What's new from the channel's release log (RELEASE-UPDATES §5).
    let releaseNotes: any ReleaseNotesRepository
    let releaseInbox: ReleaseUpdateInbox
    /// An invitation link the app was opened with (VAULT-MESSAGING §6.4): the open app's accept screen takes it.
    let inviteInbox: InviteLinkInbox
    /// Where the member is in the open app, kept while the check past the deadline takes the shell's place.
    @State private var shell: ShellModel
    /// The last phase shown before "Finish the move" began (``RootHold``).
    @State private var held: AppPhase
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    /// "Allow screenshots" (IOS-PLAN §4): it ends when the vault is no longer open, and after its hour.
    @Environment(ScreenshotAllowance.self) private var screenshots

    init(
        environment: AppEnvironment, vault: VaultManager, inbox: SetupLinkInbox, canaryInbox: CanaryManifestInbox, appLock: AppLock,
        releaseNotes: any ReleaseNotesRepository, releaseInbox: ReleaseUpdateInbox, inviteInbox: InviteLinkInbox
    ) {
        self.environment = environment
        self.vault = vault
        self.inbox = inbox
        self.canaryInbox = canaryInbox
        self.appLock = appLock
        self.releaseNotes = releaseNotes
        self.releaseInbox = releaseInbox
        self.inviteInbox = inviteInbox
        _held = State(initialValue: vault.phase)
        _shell = State(initialValue: ShellModel(account: vault, vault: vault, ownerChecks: vault.ownerChecks))
    }

    var body: some View {
        // A canary manifest handed to the app is asked about over whatever is shown (VAULT-RELEASES §10.1 step 9).
        CanaryManifestHost(inbox: canaryInbox, repo: vault.canary) {
            // IOS-PLAN §4.4 (1): the vault does not count this phone as its credential's holder; over whatever sent the
            // request, which stays. Nothing is erased.
            // The notices of a move are the root's, above every phase (vettid-android `VettIdApp`).
            VStack(spacing: 0) {
                MoveNotices(vault: vault, phase: vault.phase)
                content.credentialRequiredCover(
                    vault.credentialRequired, onRetry: { vault.credentialRequiredTryAgain() },
                    onLock: { Task { try? await vault.lock() } }
                )
            }
        }
            // The vault's time scale for every failure text below (STAGING-TIME-SCALE §5.2).
            .environment(\.vettIDTimeScale, vault.timeScale)
            .task { try? await vault.refresh() }
            // A start before the first unlock (or while the iPhone was locked) read nothing: read again once the app is
            // active and protected data is available (IOS-PLAN §6.1, §6.3).
            .onChange(of: scenePhase) { _, now in
                switch now {
                case .active:
                    // An allowance whose hour ended while the iPhone slept ends now.
                    screenshots.check()
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
            .onChange(of: vault.phase) { _, now in
                // "Finish the move" locks and unlocks the vault under the screen that asked: the root stays as it was until
                // the outcome (vettid-android `holdsRoot`).
                if !vault.finishingMove { held = now }
                closeIfNotOpen()
            }
            .onChange(of: vault.finishingMove) { _, finishing in
                guard !finishing else { return }
                held = vault.phase
                closeIfNotOpen()
            }
            // SwiftUI hands Universal Links (`applinks:`) here too, as well as the `vettid` scheme and opened files.
            .onOpenURL { url in
                // An invitation is kept until the vault is open (``OpenedLink``).
                switch OpenedLink.route(url) {
                case .invite(let link): inviteInbox.offer(link)
                case .setup(let link): inbox.offer(link)
                case .other: openFile(url)
                }
            }
    }

    /// The phase the root shows: the vault's, or while the move finishes the one before it.
    private var shownPhase: AppPhase {
        RootHold.shown(phase: vault.phase, held: held, finishingMove: vault.finishingMove)
    }

    /// A lock (or anything that leaves the open app) starts the next open afresh and ends the screenshot allowance, unless
    /// the root is held.
    private func closeIfNotOpen() {
        guard vault.phase != .unlocked, !RootHold.holds(phase: vault.phase, finishingMove: vault.finishingMove) else { return }
        shell.reset()
        // The vault is no longer open (locked, signed out, unreachable): the allowance ends.
        screenshots.vaultClosed()
    }

    private func openFile(_ url: URL) {
        if let doc = CanaryManifestFiles.receive(url) {
            // A file opened with VettID: only verified and shown; nothing is installed before the member confirms.
            canaryInbox.offer(doc)
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

    /// IOS-PLAN §6.6: what is in flight (a lock's first attempt, the outbox, a vote window's lock) is finished in a
    /// background task, within the time iOS gives it, then the collection stops (not when the app came back meanwhile). At the task's expiration the
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
        // A release update under way, or its outcome, is shown over every phase until it is left (ANDROID-PLAN "Vault
        // update").
        if vault.phase == .deleting {
            // IOS-PLAN §4.2: a vault being deleted is shown over everything else (no update, no unlock).
            VaultDeletingFlow(account: vault) { openPortal() }
        } else if vault.releaseUpdate.progress != nil {
            ReleaseUpdateFlowRoute(updates: vault.releaseUpdate)
        } else {
            phaseContent
        }
    }

    /// The move's repository, once `VaultManager` adopts ``MoveRepository`` (IOS-PLAN §8 I3.3a): until then none, and the
    /// transfer is not offered. Read through the protocol, so that this compiles before and after.
    private var move: (any MoveRepository)? { (vault as any VaultRepository) as? any MoveRepository }

    /// The onboarding flow's later screens: the recovery, the transfer from the old phone and the move's last screen when the
    /// move repository is there.
    private var onboardingRoutes: OnboardingRoutes {
        move.map { OnboardingRoutes.moves(move: $0, vault: vault, account: vault) } ?? .pending
    }

    @ViewBuilder private var phaseContent: some View {
        switch shownPhase {
        case .signedOut, .setup:
            OnboardingFlow(account: vault, vault: vault, inbox: inbox, routes: onboardingRoutes) { openPortal() }
        case .starting:
            StartingScreen()
        case .unreachable:
            UnreachableFlow(account: vault, timeScale: vault.timeScale) { openPortal() }
        case .locked:
            UnlockFlow(vault: vault, account: vault, ownerCheck: vault.ownerChecks, releaseNotes: releaseNotes) { openPortal() }
        case .deleting:
            VaultDeletingFlow(account: vault) { openPortal() }
        case .unlocked:
            // The check past the deadline closes whatever the shell had open (the drawer, the sheet, an asked check), so
            // that nothing of it comes back for a moment afterwards.
            OwnerCheckGateView(vault: vault, onGated: { shell.shown() }) { gate, now in
                AppShell(
                    account: vault, vault: vault, ownerChecks: vault.ownerChecks, credential: vault, profiles: vault.profiles,
                    appLock: appLock, model: shell, gate: gate, now: now,
                    version: .of(Bundle.main.infoDictionary ?? [:]), installedFrom: InstalledFromBuild.current,
                    promptReason: AppLockTexts.reason, canary: vault.canary, canaryInbox: canaryInbox,
                    releaseUpdates: vault.releaseUpdate, releaseNotes: releaseNotes, releaseInbox: releaseInbox,
                    connections: vault.connections, connectionRequests: vault.connections, inviteInbox: inviteInbox,
                    messages: vault.messages, attachments: vault.attachments, feed: vault.feed, approvals: vault.approvals,
                    history: vault.history, historyExport: vault.historyExport, items: vault.items, sharing: vault.sharing,
                    votes: vault.votes, move: move
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
                checks.ownerCheck, now: context.date, notices: checks.notices, presenceUnrecorded: checks.presenceUnrecorded,
                timeScale: vault.timeScale
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
