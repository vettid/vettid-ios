#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// The credential password for one critical operation on [itemName] (ANDROID-PLAN §4: every critical action asks for
/// it): a ``SecretField`` (no AutoFill, no "Save Password?", a keyboard that does not learn), a wrong password, and a
/// running backoff as a countdown. The password is the view model's, cleared after every answer. Mirrors vettid-android
/// `CredentialPasswordContent`.
struct CredentialPasswordScreen: View {
    @Environment(\.vettIDColors) private var colors
    let prompt: PasswordPrompt
    let itemName: String
    let onPassword: @MainActor (String) -> Void
    let onSubmit: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        // A running backoff counts down each second; otherwise nothing changes with time.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            form(now: context.date)
        }
    }

    private func form(now: Date) -> some View {
        FormScaffold(
            title: prompt.title,
            message: ItemsStrings.passwordBody(itemName),
            primaryLabel: prompt.purpose == .delete ? ItemsStrings.delete : ItemsStrings.passwordContinue,
            primaryEnabled: prompt.canSend(now),
            busy: prompt.busy,
            destructive: prompt.purpose == .delete,
            secondaryLabel: ItemsStrings.cancel,
            onPrimary: onSubmit,
            onSecondary: onCancel,
            onBack: onCancel,
            header: { HeaderGlyph(symbol: .lock) }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                SecretField(
                    ItemsStrings.passwordLabel,
                    text: Binding(get: { prompt.password }, set: { onPassword($0) }),
                    error: prompt.errorText(now),
                    spokenError: prompt.spokenError(now),
                    errorPriority: .assertive,
                    onSubmit: { if prompt.canSend(Date()) { onSubmit() } }
                )
                .disabled(prompt.busy)
                .accessibilityIdentifier("items_password_field")
                Text(ItemsStrings.passwordNote).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
            }
        }
        .accessibilityIdentifier("items_password")
    }
}
#endif
