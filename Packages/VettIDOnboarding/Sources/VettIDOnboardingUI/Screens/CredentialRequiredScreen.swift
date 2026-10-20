#if os(iOS)
import SwiftUI
import VettIDData
import VettIDUI

/// IOS-PLAN §4.4 (1), §4.5 (3): the vault answered `credential_required` (with or without `{"reason": "no_holder"}`) to a
/// request the member sent: it does not count this phone as the holder of its credential and refuses its requests. A full
/// screen over the screen that sent the request, from any screen (``VaultManager/credentialRequired``; see
/// ``SwiftUI/View/credentialRequiredCover(_:onRetry:onLock:)``): "Try again" ([onRetry]) and "Lock vault" ([onLock],
/// `vault.lock`, allowed without a holder, then the unlock screen). Nothing is erased. The texts are vettid-android's
/// (ANDROID-PLAN 0.1.57 §4 "Vault error codes the app does not map"); a recovery's time at the vault's time scale.
public struct CredentialRequiredScreen: View {
    let onRetry: @MainActor () -> Void
    let onLock: @MainActor () -> Void
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTimeScale) private var timeScale

    public init(onRetry: @escaping @MainActor () -> Void, onLock: @escaping @MainActor () -> Void) {
        self.onRetry = onRetry
        self.onLock = onLock
    }

    public var body: some View {
        FormScaffold(
            title: FailureKind.credentialRequiredTitle,
            message: FailureKind.credentialRequired.message(timeScale: timeScale),
            primaryLabel: OnboardingStrings.rootRetry,
            secondaryLabel: OnboardingStrings.ownerCheckLock,
            onPrimary: onRetry,
            onSecondary: onLock
        ) {
            EmptyView()
        }
        .background(colors.background.color.ignoresSafeArea())
        .accessibilityIdentifier("credential_required")
    }
}

public extension View {
    /// ``CredentialRequiredScreen`` over this view while [shown]: what is under it stays (a screen's own state, such as a
    /// daily check the member opened, comes back after "Try again"), hidden from VoiceOver and out of reach.
    func credentialRequiredCover(
        _ shown: Bool, onRetry: @escaping @MainActor () -> Void, onLock: @escaping @MainActor () -> Void
    ) -> some View {
        accessibilityHidden(shown)
            .allowsHitTesting(!shown)
            .overlay {
                if shown { CredentialRequiredScreen(onRetry: onRetry, onLock: onLock) }
            }
    }
}
#endif
