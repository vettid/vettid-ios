import Combine
import SwiftUI
import UIKit
import VettIDAltChan
import VettIDData
import VettIDOnboardingUI
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

/// The root: onboarding while nothing is set up or setup is under way (IOS-PLAN §8 I1.6), the placeholder for the
/// screens of the later rows otherwise. Debug builds can open the debug catalog from it.
struct RootView: View {
    let environment: AppEnvironment
    let composition: AppComposition
    @Binding var themeMode: ThemeMode

    var body: some View {
        #if DEBUG
        DebugCatalog(themeMode: $themeMode) {
            AppRoot(environment: environment, vault: composition.vault, inbox: composition.inbox)
        }
        #else
        AppRoot(environment: environment, vault: composition.vault, inbox: composition.inbox)
        #endif
    }
}

/// Follows the vault manager's phase (vettid-android `VettIdApp`'s root): the phase is read at start; a setup link the
/// app was opened with goes to the onboarding flow, which redeems it only while nothing is set up.
struct AppRoot: View {
    let environment: AppEnvironment
    let vault: VaultManager
    let inbox: SetupLinkInbox
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .task { try? await vault.refresh() }
            // A start before the first unlock (or while the iPhone was locked) read nothing: read again once the app is
            // active and protected data is available (IOS-PLAN §6.1, §6.3).
            .onChange(of: scenePhase) { _, now in
                if now == .active { retryRefresh() }
            }
            .onReceive(Self.protectedDataAvailable) { _ in retryRefresh() }
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

    @ViewBuilder private var content: some View {
        switch vault.phase {
        case .signedOut, .setup:
            OnboardingFlow(account: vault, vault: vault, inbox: inbox, routes: .pending) {
                if let url = URL(string: environment.apiOrigin) { openURL(url) }
            }
        // The unlock, the stuck screens and the app's shell come with I1.7 and I1.8.
        case .starting, .unreachable, .locked, .unlocked:
            Placeholder(environment: environment)
        }
    }
}

/// Placeholder until the screens of IOS-PLAN §4 arrive.
struct Placeholder: View {
    let environment: AppEnvironment
    @Environment(\.vettIDColors) private var colors

    var body: some View {
        VStack(spacing: Spacing.l) {
            RookLogo(height: 72)
            Text(verbatim: environment.kind.rawValue)
                .vettIDFont(.bodyMedium)
                .foregroundStyle(colors.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.background)
    }
}
