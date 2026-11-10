#if os(iOS)
import SwiftUI
import VettIDData
import VettIDDevices
import VettIDUI

/// The short message at the bottom (Android's snackbar): "<name> was removed", "Access ended". Spoken when it appears.
struct DeviceToast: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    var body: some View {
        Text(text)
            .vettIDFont(.bodyMedium)
            .foregroundStyle(colors.inverseOnSurface)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.l)
            .background(colors.inverseSurface, in: RoundedRectangle(cornerRadius: VettIDShape.small, style: .continuous))
            .padding(.horizontal, Spacing.gutter)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("device_toast")
    }
}

/// How long a toast stays.
private let toastSeconds = 4.0

extension View {
    /// Shows [text] as a toast over the bottom of this view for a few seconds whenever it changes to a new non-nil text, and
    /// tells VoiceOver. [onShown] runs when it appears (the screen tells its model that it was shown once).
    func deviceToast(_ text: String?, bottom: CGFloat = Spacing.l, onShown: @escaping @MainActor () -> Void = {}) -> some View {
        modifier(DeviceToastModifier(text: text, bottom: bottom, onShown: onShown))
    }
}

private struct DeviceToastModifier: ViewModifier {
    let text: String?
    let bottom: CGFloat
    let onShown: @MainActor () -> Void
    @State private var shown: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let shown { DeviceToast(text: shown).padding(.bottom, bottom) }
            }
            .onChange(of: text, initial: true) { _, now in
                guard let now else { return }
                onShown()
                shown = now
                Announcer.announce(now, .polite)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(toastSeconds))
                    if shown == now { shown = nil }
                }
            }
    }
}

/// A notice's text action ("Try again", "OK").
struct DeviceTextAction: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    var identifier = ""
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).vettIDFont(.labelLarge, weight: .semibold).foregroundStyle(colors.primary).textButtonTarget()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// The tile's colours: agents orange, desktops purple.
func deviceTileColors(_ d: DeviceInfo, dark: Bool) -> TagColor { CategoryColors.of(d.isAgent ? .orange : .purple, dark: dark) }
#endif
