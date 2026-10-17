import SwiftUI

/// The colours of a tag in the current theme; [stored] when the caller has the registry entry, else the environment's
/// registry colours.
struct TagColorReader {
    let colors: VettIDColors
    let registry: [String: String]

    func color(_ tag: String, stored: String? = nil) -> TagColor {
        TagColors.of(tag, dark: colors.isDark, stored: stored ?? registry[TagColors.normalize(tag)])
    }
}

/// An item tag as a small pill in the tag's own colour (``TagColors``; `@profile` is gold). [label] is what is shown
/// ("Shared profile" for `@profile`), [tag] the tag itself, which picks the colour. Mirrors vettid-android `TagChip`.
public struct TagChip: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTagColors) private var registry
    let label: String
    let tag: String

    public init(_ label: String, tag: String? = nil) {
        self.label = label
        self.tag = tag ?? label
    }

    public var body: some View {
        let c = TagColorReader(colors: colors, registry: registry).color(tag)
        Text(label)
            .vettIDFont(.labelMedium)
            .foregroundStyle(c.onContainer)
            .lineLimit(1)
            .padding(.horizontal, Spacing.s + Spacing.xxs)
            .padding(.vertical, Spacing.xxs)
            .background(c.container, in: VettIDShape.pill)
            .accessibilityIdentifier("tag_chip_\(tag)")
    }
}

/// A row's tags on one line: the first [max] as ``TagChip``s, then "+N" for the rest. Mirrors vettid-android
/// `TagChipLine`.
public struct TagChipLine: View {
    @Environment(\.vettIDColors) private var colors
    let tags: [String]
    let label: (String) -> String
    let max: Int

    public init(_ tags: [String], max: Int = 3, label: @escaping (String) -> String) {
        self.tags = tags
        self.max = max
        self.label = label
    }

    public var body: some View {
        if !tags.isEmpty {
            HStack(spacing: Spacing.xs) {
                ForEach(tags.prefix(max), id: \.self) { TagChip(label($0), tag: $0) }
                let more = tags.count - max
                if more > 0 {
                    Text(UIStrings.tagsMore(more))
                        .vettIDFont(.labelMedium)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .accessibilityLabel(UIStrings.tagsMoreDescription(more))
                }
            }
        }
    }
}

/// A small dot in a tag's colour (a tag's choice in a menu); [stored] is its registry colour when the caller has it.
public struct TagDot: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTagColors) private var registry
    let tag: String
    let stored: String?

    public init(_ tag: String, stored: String? = nil) {
        self.tag = tag
        self.stored = stored
    }

    public var body: some View {
        Circle()
            .fill(TagColorReader(colors: colors, registry: registry).color(tag, stored: stored).container)
            .frame(width: 12, height: 12)
    }
}

/// A removable tag (the item editor): a chip in the tag's colour with a close icon. [removeLabel] is the close
/// icon's accessibility label ("Remove tag travel"). Mirrors vettid-android `RemovableTagChip`.
public struct RemovableTagChip: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTagColors) private var registry
    let label: String
    let tag: String
    let removeLabel: String
    let onRemove: @MainActor () -> Void

    public init(_ label: String, tag: String, removeLabel: String, onRemove: @escaping @MainActor () -> Void) {
        self.label = label
        self.tag = tag
        self.removeLabel = removeLabel
        self.onRemove = onRemove
    }

    public var body: some View {
        let c = TagColorReader(colors: colors, registry: registry).color(tag)
        Button(action: onRemove) {
            HStack(spacing: Spacing.s) {
                Text(label).vettIDFont(.labelLarge).lineLimit(1)
                VettIDSymbol.close.image.font(.system(size: 13, weight: .semibold))
            }
            .fixedSize()
            .foregroundStyle(c.onContainer)
            .padding(.leading, Spacing.m)
            .padding(.trailing, Spacing.s)
            .frame(minHeight: 32)
            .background(c.container, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(removeLabel)
    }
}

/// A selectable filter chip (Material's `FilterChip`): outlined, gold-tinted with a check mark while selected.
public struct VettIDFilterChip: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let selected: Bool
    let action: @MainActor () -> Void

    public init(_ label: String, selected: Bool, action: @escaping @MainActor () -> Void) {
        self.label = label
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).accessibilityHidden(true)
                }
                Text(label).vettIDFont(.labelLarge).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(selected ? colors.onSecondaryContainer : colors.onSurfaceVariant)
            .padding(.horizontal, Spacing.m + Spacing.xxs)
            .frame(minHeight: 32)
            .background(selected ? colors.secondaryContainer : ThemeColor(0, alpha: 0), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? ThemeColor(0, alpha: 0) : colors.outline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// "✕ Clear" at the end of a row of filter chips, shown by the caller exactly while a filter is on: one tap clears
/// every filter (owner request 2026-10-09). Mirrors vettid-android `ClearFiltersChip`.
public struct ClearFiltersChip: View {
    @Environment(\.vettIDColors) private var colors
    let action: @MainActor () -> Void

    public init(action: @escaping @MainActor () -> Void) { self.action = action }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                VettIDSymbol.close.image.font(.system(size: 13, weight: .semibold))
                Text(UIStrings.clear).vettIDFont(.labelLarge).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(colors.onSurfaceVariant)
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: 32)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(colors.outline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(UIStrings.clearFilters)
        .accessibilityIdentifier("clear_filters")
    }
}

/// A row of filter chips that scrolls sideways, ended by ``ClearFiltersChip`` while [filtering]: the clear chip stays
/// at the row's end, outside the scroll, so it is in view however many chips there are. Mirrors vettid-android
/// `FilterChipRow`.
public struct FilterChipRow<Chips: View>: View {
    let filtering: Bool
    let onClear: @MainActor () -> Void
    let chips: Chips

    public init(filtering: Bool, onClear: @escaping @MainActor () -> Void, @ViewBuilder chips: () -> Chips) {
        self.filtering = filtering
        self.onClear = onClear
        self.chips = chips()
    }

    public var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) { chips }
                    .padding(.leading, Spacing.gutter)
                    .padding(.trailing, filtering ? Spacing.s : Spacing.gutter)
            }
            if filtering {
                ClearFiltersChip(action: onClear).padding(.trailing, Spacing.gutter)
            }
        }
    }
}
