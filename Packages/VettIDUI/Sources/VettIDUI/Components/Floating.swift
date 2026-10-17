import SwiftUI

/// Bottom overlay row for list screens: a filter chip at the start and the primary action at the end (Proton: Unread
/// and compose). Place it in an overlay aligned to the bottom. Mirrors vettid-android `BottomFloatingControls`.
public struct BottomFloatingControls<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack {
            leading
            Spacer()
            trailing
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.l)
    }
}

/// Floating toggle chip (Proton's "Unread"). Selected = gold fill. Mirrors vettid-android `FloatingFilterChip`.
public struct FloatingFilterChip: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    @Binding var selected: Bool

    public init(_ label: String, selected: Binding<Bool>) {
        self.label = label
        _selected = selected
    }

    public var body: some View {
        Button { selected.toggle() } label: {
            Text(label)
                .vettIDFont(.labelLarge)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(selected ? colors.onPrimaryContainer : colors.onSurface)
                .padding(.horizontal, Spacing.xl)
                .frame(minHeight: 56)
                .background(selected ? colors.primaryContainer : colors.surfaceContainer, in: VettIDShape.pill)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(selected ? UIStrings.filterOn(label) : UIStrings.filterOff(label))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Round floating action button (Proton compose): neutral surface, gold icon. Mirrors vettid-android `VettIdFab`.
public struct VettIDFab: View {
    @Environment(\.vettIDColors) private var colors
    let icon: VettIDSymbol
    let label: String
    let action: @MainActor () -> Void

    public init(_ icon: VettIDSymbol, label: String, action: @escaping @MainActor () -> Void) {
        self.icon = icon
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            icon.image
                .font(.system(size: 22))
                .foregroundStyle(colors.primary)
                .frame(width: 56, height: 56)
                .background(colors.surfaceContainer, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// One action of a ``FloatingPillActionBar``.
public struct PillAction: Identifiable {
    public let icon: VettIDSymbol
    public let label: String
    public let destructive: Bool
    public let action: @MainActor () -> Void

    public init(_ icon: VettIDSymbol, label: String, destructive: Bool = false, action: @escaping @MainActor () -> Void) {
        self.icon = icon
        self.label = label
        self.destructive = destructive
        self.action = action
    }

    public var id: String { label }
}

/// Floating pill of icon actions at the bottom of a detail screen (Proton). Mirrors vettid-android
/// `FloatingPillActionBar`.
public struct FloatingPillActionBar: View {
    @Environment(\.vettIDColors) private var colors
    let actions: [PillAction]

    public init(_ actions: [PillAction]) { self.actions = actions }

    public var body: some View {
        HStack(spacing: Spacing.xxs * 2) {
            ForEach(actions) { a in
                IconButton(a.icon, label: a.label, tint: a.destructive ? colors.error : colors.onSurface, action: a.action)
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .background(colors.surfaceContainer, in: VettIDShape.pill)
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        .padding(.bottom, Spacing.l)
    }
}
