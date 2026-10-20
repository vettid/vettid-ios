#if os(iOS)
import SwiftUI
import VettIDData
import VettIDUI

/// IOS-PLAN §4.4 (1), §4.5 (3): the vault answered `credential_required` (with or without `{"reason": "no_holder"}`): it
/// does not count this phone as the holder of its credential and refuses its requests. A full screen in place of the
/// screen that sent the request, from any screen (``VaultManager/credentialRequired``): "Try again" ([onRetry]) and "Lock
/// vault" ([onLock], `vault.lock`, allowed without a holder, then the unlock screen). Nothing is erased. The texts are
/// vettid-android's (ANDROID-PLAN 0.1.57 §4 "Vault error codes the app does not map").
public struct CredentialRequiredScreen: View {
    let onRetry: @MainActor () -> Void
    let onLock: @MainActor () -> Void

    public init(onRetry: @escaping @MainActor () -> Void, onLock: @escaping @MainActor () -> Void) {
        self.onRetry = onRetry
        self.onLock = onLock
    }

    public var body: some View {
        FormScaffold(
            title: FailureKind.credentialRequiredTitle,
            message: FailureKind.credentialRequired.message,
            primaryLabel: OnboardingStrings.rootRetry,
            secondaryLabel: OnboardingStrings.ownerCheckLock,
            onPrimary: onRetry,
            onSecondary: onLock
        ) {
            EmptyView()
        }
        .accessibilityIdentifier("credential_required")
    }
}
#endif
