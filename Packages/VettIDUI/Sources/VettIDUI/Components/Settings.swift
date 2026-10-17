import SwiftUI

/// Section header above a settings group (Proton "Preferences"). Mirrors vettid-android `SettingsSectionHeader`.
public struct SettingsSectionHeader: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .vettIDFont(.titleSmall)
            .foregroundStyle(colors.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Spacing.gutter + Spacing.xs)
            .padding(.trailing, Spacing.gutter)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.m)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rounded card grouping settings rows, separated by ``SettingsDivider``s in the screen colour (Proton).
/// Mirrors vettid-android `SettingsGroup`.
public struct SettingsGroup<Content: View>: View {
    @Environment(\.vettIDColors) private var colors
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(spacing: 0) { content }
            .background(colors.card, in: VettIDShape.card)
            .clipShape(VettIDShape.card)
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.xs + Spacing.xxs)
    }
}

/// The hairline between two rows of a ``SettingsGroup``.
public struct SettingsDivider: View {
    @Environment(\.vettIDColors) private var colors

    public init() {}

    public var body: some View { Hairline(color: colors.groupedBackground, thickness: 2) }
}

/// Settings row: icon, label (with optional supporting text and tag), chevron. Mirrors vettid-android `SettingsRow`.
public struct SettingsRow: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let icon: VettIDSymbol?
    let iconTint: ThemeColor?
    let supporting: String?
    let tag: String?
    let showChevron: Bool
    let action: @MainActor () -> Void

    public init(
        _ label: String,
        icon: VettIDSymbol? = nil,
        iconTint: ThemeColor? = nil,
        supporting: String? = nil,
        tag: String? = nil,
        showChevron: Bool = true,
        action: @escaping @MainActor () -> Void
    ) {
        self.label = label
        self.icon = icon
        self.iconTint = iconTint
        self.supporting = supporting
        self.tag = tag
        self.showChevron = showChevron
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            SettingsRowLayout(label: label, supporting: supporting, tag: tag) {
                if let icon { RowIcon(icon: icon, tint: iconTint) }
            } trailing: {
                if showChevron {
                    VettIDSymbol.chevronForward.image
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.onSurfaceVariant)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(RowPressStyle())
    }
}

/// Settings row with a switch; the whole row toggles. Mirrors vettid-android `SettingsSwitchRow`.
public struct SettingsSwitchRow: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let icon: VettIDSymbol?
    let supporting: String?
    @Binding var isOn: Bool

    public init(_ label: String, isOn: Binding<Bool>, icon: VettIDSymbol? = nil, supporting: String? = nil) {
        self.label = label
        _isOn = isOn
        self.icon = icon
        self.supporting = supporting
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            SettingsRowLayout(label: label, supporting: supporting, tag: nil, horizontalPadding: false) {
                if let icon { RowIcon(icon: icon, tint: nil) }
            } trailing: {
                EmptyView()
            }
        }
        .tint(colors.primary.color)
        .padding(.horizontal, Spacing.xl)
    }
}

/// Account row at the top of Settings: avatar tile, name, address, chevron. Mirrors vettid-android
/// `SettingsAccountRow`.
public struct SettingsAccountRow: View {
    @Environment(\.vettIDColors) private var colors
    let name: String
    let detail: String
    let photo: UIImage?
    let action: @MainActor () -> Void

    public init(name: String, detail: String, photo: UIImage? = nil, action: @escaping @MainActor () -> Void) {
        self.name = name
        self.detail = detail
        self.photo = photo
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            SettingsRowLayout(label: name, supporting: detail, tag: nil, minHeight: 88) {
                InitialTile(name, size: 40, style: .ownAccount, photo: photo)
            } trailing: {
                VettIDSymbol.chevronForward.image
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.onSurfaceVariant)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(RowPressStyle())
    }
}

/// A read-only settings row: label and value (status screens). Not tappable; read as one item.
/// Mirrors vettid-android `SettingsInfoRow`.
public struct SettingsInfoRow: View {
    let label: String
    let value: String
    let icon: VettIDSymbol?

    public init(_ label: String, value: String, icon: VettIDSymbol? = nil) {
        self.label = label
        self.value = value
        self.icon = icon
    }

    public var body: some View {
        SettingsRowLayout(label: label, supporting: value, tag: nil) {
            if let icon { RowIcon(icon: icon, tint: nil) }
        } trailing: {
            EmptyView()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RowIcon: View {
    @Environment(\.vettIDColors) private var colors
    let icon: VettIDSymbol
    let tint: ThemeColor?

    var body: some View {
        icon.image
            .font(.system(size: 20))
            .foregroundStyle(tint ?? colors.onSurface)
            .frame(width: 24)
            .accessibilityHidden(true)
    }
}

private struct SettingsRowLayout<Leading: View, Trailing: View>: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.dynamicTypeSize) private var typeSize
    let label: String
    let supporting: String?
    let tag: String?
    var minHeight: CGFloat = 72
    var horizontalPadding = true
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    init(
        label: String,
        supporting: String?,
        tag: String?,
        minHeight: CGFloat = 72,
        horizontalPadding: Bool = true,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.label = label
        self.supporting = supporting
        self.tag = tag
        self.minHeight = minHeight
        self.horizontalPadding = horizontalPadding
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: Spacing.xl) {
                leading
                VStack(alignment: .leading, spacing: 0) {
                    let lines = typeSize.isAccessibilitySize ? nil : 2
                    let title = Text(label).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurface).lineLimit(lines)
                    if let tag {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Spacing.s) { title.fixedSize(); TagLabel(tag).fixedSize() }
                            VStack(alignment: .leading, spacing: Spacing.xxs) { title; TagLabel(tag) }
                        }
                    } else {
                        title
                    }
                    if let supporting {
                        Text(supporting)
                            .vettIDFont(.bodyMedium)
                            .foregroundStyle(colors.onSurfaceVariant)
                            .lineLimit(lines)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            trailing.padding(.leading, Spacing.m)
        }
        .padding(.horizontal, horizontalPadding ? Spacing.xl : 0)
        .padding(.vertical, Spacing.m)
        .frame(minHeight: minHeight)
        .contentShape(Rectangle())
    }
}

/// Highlights a row while pressed (Material's ripple), in the row's card.
struct RowPressStyle: ButtonStyle {
    @Environment(\.vettIDColors) private var colors

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? colors.onSurface.opacity(0.08) : ThemeColor(0, alpha: 0))
    }
}

/// Account sheet (Proton): large avatar tile, name and detail, then option groups. Usable without the sheet (gallery,
/// previews); it scrolls, as on a phone the options are taller than the screen. Mirrors vettid-android
/// `AvatarSheetContent`; present it with ``SwiftUICore/View/avatarSheet(isPresented:content:)``.
public struct AvatarSheetContent<Content: View>: View {
    @Environment(\.vettIDColors) private var colors
    let name: String
    let detail: String
    let optionsHeader: String?
    let photo: UIImage?
    let content: Content

    public init(
        name: String,
        detail: String,
        optionsHeader: String? = nil,
        photo: UIImage? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.name = name
        self.detail = detail
        self.optionsHeader = optionsHeader
        self.photo = photo
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                InitialTile(name, size: 88, style: .ownAccount, photo: photo)
                Spacer().frame(height: Spacing.l)
                Text(name)
                    .vettIDFont(.titleLarge, weight: .bold)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .vettIDFont(.bodyLarge)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                Spacer().frame(height: Spacing.l)
                VStack(spacing: 0) {
                    if let optionsHeader { SettingsSectionHeader(optionsHeader) }
                    content
                }
            }
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.l)
            .accessibilityIdentifier("avatar_sheet_content")
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

public extension View {
    /// Presents an account sheet at the large detent (IOS-PLAN §3), on the grouped background.
    func avatarSheet<Sheet: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Sheet) -> some View {
        modifier(AvatarSheetModifier(isPresented: isPresented, sheet: content))
    }

    /// A confirmation dialog. Every destructive action goes through one (ANDROID-PLAN §4); [destructive] gives the
    /// confirm button the destructive role (red). Mirrors vettid-android `ConfirmDialog`.
    func confirmDialog(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        confirmLabel: String,
        destructive: Bool = false,
        dismissLabel: String? = nil,
        onConfirm: @escaping @MainActor () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            Button(confirmLabel, role: destructive ? .destructive : nil, action: onConfirm)
                .accessibilityIdentifier("confirm_button")
            Button(dismissLabel ?? UIStrings.cancel, role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

private struct AvatarSheetModifier<Sheet: View>: ViewModifier {
    @Environment(\.vettIDColors) private var colors
    @Binding var isPresented: Bool
    let sheet: () -> Sheet

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            sheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(colors.groupedBackground.color)
                .environment(\.vettIDColors, colors)
        }
    }
}
