#if os(iOS)
import SwiftUI
import VettIDUI

/// (ANDROID-PLAN 0.1.124) In place of the entries while the vault verifies: a centered progress indicator and its line,
/// announced when it appears.
struct CheckingWithVault: View {
    var body: some View {
        VStack(spacing: Spacing.l) {
            ProgressView().controlSize(.large).accessibilityHidden(true)
            Text(OnboardingStrings.ownerCheckChecking)
                .vettIDFont(.bodyLarge)
                .multilineTextAlignment(.center)
                .announced(OnboardingStrings.ownerCheckChecking)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("owner_check_checking")
    }
}

/// (ANDROID-PLAN 0.1.124) A pass: the green tick and "Check passed", no actions. The tick says nothing by itself (its
/// meaning is the text, not its colour); ``OwnerCheckFlow`` holds it and then closes the screen.
struct PassedTick: View {
    let title: String
    @Environment(\.vettIDColors) private var colors

    var body: some View {
        FormScaffold(title: title, primaryLabel: nil, onPrimary: {}) {
            VStack(spacing: Spacing.l) {
                VettIDSymbol.checkCircle.image
                    .font(.system(size: 64))
                    .foregroundStyle(colors.success)
                    .accessibilityHidden(true)
                Text(OnboardingStrings.ownerCheckPassed)
                    .vettIDFont(.titleMedium)
                    .multilineTextAlignment(.center)
                    .announced(OnboardingStrings.ownerCheckPassed)
                    .accessibilityIdentifier("owner_check_passed_text")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xl)
        }
        // Nothing to go back to while the tick is held (the shell's block holds it; this one, were the screen pushed).
        .blocksBackGesture(true)
        .accessibilityIdentifier("owner_check_passed")
    }
}
#endif
