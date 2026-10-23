#if os(iOS)
import SwiftUI
import VettIDData
import VettIDUI

/// Kept out of screenshots and screen recordings (IOS-PLAN §6.4 protection 3) unless the member allowed screenshots
/// (Settings → App): a pasted transfer code, and the safety code. vettid-android keeps the whole app out of
/// captures (`FLAG_SECURE`); on the iPhone these codes are what a capture must not carry, on top of the app-switcher cover
/// and capture hiding that are always on (chosen; not in the spec). The same rule as the connect screens' own.
struct CaptureProtected<Content: View>: View {
    @Environment(ScreenshotAllowance.self) private var allowance: ScreenshotAllowance?
    @ViewBuilder let content: () -> Content

    var body: some View {
        SecureContainer(isSecure: !(allowance?.allowed ?? false)) { content() }
    }
}

/// The safety code, large, in a bordered box (VAULT-MESSAGING §6.3), out of captures. Mirrors vettid-android `SasBox`.
struct SasBox: View {
    @Environment(\.vettIDColors) private var colors
    let sas: String

    var body: some View {
        CaptureProtected {
            SafetyCode(sas)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.l)
                .overlay(VettIDShape.card.stroke(colors.outline, lineWidth: 1))
        }
        .accessibilityIdentifier("sas")
    }
}

/// A spinner and what is awaited, announced when it appears. Mirrors vettid-android `Waiting`.
struct WaitingRow: View {
    @Environment(\.vettIDColors) private var colors
    let text: String
    var identifier = "waiting"

    var body: some View {
        HStack(spacing: Spacing.m) {
            ProgressView().controlSize(.small).tint(colors.primary.color)
            Text(text).vettIDFont(.bodyMedium)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier(identifier)
    }
}
#endif
