#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDUI

/// "Your vault is being deleted" (IOS-PLAN §4.2), over every screen once the vault said so, with its view model.
/// [onOpenAccountSite]: the account site, where the member gets a setup code once the deletion is done.
public struct VaultDeletingFlow: View {
    private let account: any AccountRepository
    private let onOpenAccountSite: @MainActor () -> Void
    @State private var model: VaultDeletingViewModel?

    public init(account: any AccountRepository, onOpenAccountSite: @escaping @MainActor () -> Void) {
        self.account = account
        self.onOpenAccountSite = onOpenAccountSite
    }

    public var body: some View {
        VaultDeletingScreen(
            state: model?.state ?? VaultDeletingState(slow: account.deletion?.slow ?? false),
            onCheckAgain: { model?.checkAgain() }, onOpenAccountSite: onOpenAccountSite,
            onAskRemove: { model?.askRemove() }, onDismissRemove: { model?.dismissRemove() },
            onConfirmRemove: { model?.confirmRemove() }
        )
        .onAppear { if model == nil { model = VaultDeletingViewModel(account: account) } }
    }
}

/// The screen for [state] (stateless): while waiting, a progress indicator without a percentage; after the bound, the
/// neutral "still finishing" text and Check again. Open the account site in both. The title is announced politely when
/// it appears or changes.
public struct VaultDeletingScreen: View {
    let state: VaultDeletingState
    let onCheckAgain: @MainActor () -> Void
    let onOpenAccountSite: @MainActor () -> Void
    let onAskRemove: @MainActor () -> Void
    let onDismissRemove: @MainActor () -> Void
    let onConfirmRemove: @MainActor () -> Void
    @Environment(\.vettIDColors) private var colors

    public init(
        state: VaultDeletingState, onCheckAgain: @escaping @MainActor () -> Void = {},
        onOpenAccountSite: @escaping @MainActor () -> Void = {}, onAskRemove: @escaping @MainActor () -> Void = {},
        onDismissRemove: @escaping @MainActor () -> Void = {}, onConfirmRemove: @escaping @MainActor () -> Void = {}
    ) {
        self.state = state
        self.onCheckAgain = onCheckAgain
        self.onOpenAccountSite = onOpenAccountSite
        self.onAskRemove = onAskRemove
        self.onDismissRemove = onDismissRemove
        self.onConfirmRemove = onConfirmRemove
    }

    var title: String { state.slow ? OnboardingStrings.vaultDeletingSlowTitle : OnboardingStrings.vaultDeletingTitle }

    public var body: some View {
        FormScaffold(
            title: title,
            message: state.slow ? OnboardingStrings.vaultDeletingSlowBody : OnboardingStrings.vaultDeletingBody,
            primaryLabel: state.slow ? OnboardingStrings.vaultDeletingCheckAgain : OnboardingStrings.vaultDeletingAccountSite,
            primaryEnabled: !state.checking,
            busy: state.checking,
            secondaryLabel: state.slow ? OnboardingStrings.vaultDeletingAccountSite : nil,
            onPrimary: state.slow ? onCheckAgain : onOpenAccountSite,
            onSecondary: onOpenAccountSite
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if !state.slow {
                    ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("vault_deleting_progress")
                }
                if state.slow && state.note == nil {
                    Text(OnboardingStrings.vaultDeletingUnconfirmed)
                        .vettIDFont(.bodyMedium)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .accessibilityIdentifier("vault_deleting_unconfirmed")
                }
                if let note = state.note {
                    Text(noteText(note))
                        .vettIDFont(.bodyMedium)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .accessibilityIdentifier("vault_deleting_note")
                    if note == .cannotConfirmClock {
                        Text(OnboardingStrings.vaultDeletingClockHint)
                            .vettIDFont(.bodyMedium)
                            .foregroundStyle(colors.onSurfaceVariant)
                            .accessibilityIdentifier("vault_deleting_clock_hint")
                    }
                }
                if state.slow {
                    TextLink(OnboardingStrings.vaultDeletingRemove) { onAskRemove() }
                        .disabled(state.removing)
                        .accessibilityIdentifier("vault_deleting_remove")
                }
            }
        }
        .confirmDialog(
            isPresented: Binding(get: { state.removeConfirm }, set: { if !$0 { onDismissRemove() } }),
            title: OnboardingStrings.vaultDeletingRemoveConfirmTitle,
            message: OnboardingStrings.vaultDeletingRemoveConfirmBody,
            confirmLabel: OnboardingStrings.vaultDeletingRemoveConfirm,
            destructive: true
        ) { onConfirmRemove() }
        .onAppear { announce() }
        .onChange(of: state.slow) { _, _ in announce() }
        .accessibilityIdentifier(state.slow ? "vault_deleting_slow" : "vault_deleting")
    }

    private func noteText(_ note: DeletionCheckNote) -> String {
        switch note {
        case .still: OnboardingStrings.vaultDeletingStill
        case .unreachable: OnboardingStrings.vaultDeletingUnreachable
        case .cannotConfirm, .cannotConfirmClock: OnboardingStrings.vaultDeletingCannotConfirm
        }
    }

    private func announce() {
        var s = AttributedString(title)
        s.accessibilitySpeechAnnouncementPriority = .default
        AccessibilityNotification.Announcement(s).post()
    }
}
#endif
