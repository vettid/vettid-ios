import SwiftUI

/// Trailing icon action on a ``VettIDListRow`` (Proton's star).
public struct RowAction {
    public let icon: VettIDSymbol
    public let label: String
    public let active: Bool
    public let action: @MainActor () -> Void

    public init(icon: VettIDSymbol, label: String, active: Bool = false, action: @escaping @MainActor () -> Void) {
        self.icon = icon
        self.label = label
        self.active = active
        self.action = action
    }
}

/// List row (Proton mailbox): initial tile, name and preview lines, date on the first line's end and an optional
/// trailing action under it. [emphasized] marks unread rows (bold, full-contrast text); [tileStyle] marks favourites;
/// [tileColors] colours the tile (a tag's colour). [below] goes under the preview line (an item's tags).
/// Mirrors vettid-android `VettIdListRow`.
public struct VettIDListRow<Below: View>: View {
    @Environment(\.vettIDColors) private var colors
    let title: String
    let supporting: String?
    let meta: String?
    let tileName: String
    let tileStyle: TileStyle
    let emphasized: Bool
    let rowAction: RowAction?
    let tilePhoto: UIImage?
    let tileIcon: VettIDSymbol?
    let tileColors: TagColor?
    let onTap: (@MainActor () -> Void)?
    let below: Below

    public init(
        title: String,
        supporting: String? = nil,
        meta: String? = nil,
        tileName: String? = nil,
        tileStyle: TileStyle = .connection,
        emphasized: Bool = false,
        action: RowAction? = nil,
        tilePhoto: UIImage? = nil,
        tileIcon: VettIDSymbol? = nil,
        tileColors: TagColor? = nil,
        onTap: (@MainActor () -> Void)? = nil,
        @ViewBuilder below: () -> Below = { EmptyView() }
    ) {
        self.title = title
        self.supporting = supporting
        self.meta = meta
        self.tileName = tileName ?? title
        self.tileStyle = tileStyle
        self.emphasized = emphasized
        self.rowAction = action
        self.tilePhoto = tilePhoto
        self.tileIcon = tileIcon
        self.tileColors = tileColors
        self.onTap = onTap
        self.below = below()
    }

    public var body: some View {
        let lineColor = emphasized ? colors.onSurface : colors.onSurfaceVariant
        let weight: Font.Weight = emphasized ? .semibold : .regular
        HStack(alignment: .center, spacing: 0) {
            InitialTile(tileName, size: 40, style: tileStyle, photo: tilePhoto, icon: tileIcon, colors: tileColors)
            Spacer().frame(width: Spacing.l)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(title)
                        .vettIDFont(.bodyLarge, weight: weight)
                        .foregroundStyle(lineColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let meta {
                        Text(meta)
                            .vettIDFont(.bodySmall, weight: weight)
                            .foregroundStyle(lineColor)
                            .padding(.leading, Spacing.s)
                            .padding(.trailing, Spacing.m)
                    }
                }
                HStack(spacing: 0) {
                    if let supporting {
                        Text(supporting)
                            .vettIDFont(.bodyMedium)
                            .foregroundStyle(lineColor)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer()
                    }
                    if let rowAction {
                        IconButton(
                            rowAction.icon,
                            label: rowAction.label,
                            tint: rowAction.active ? colors.primary : colors.onSurfaceVariant,
                            action: rowAction.action
                        )
                    }
                }
                below.padding(.top, Spacing.xs)
            }
        }
        .padding(.leading, Spacing.gutter)
        .padding(.trailing, Spacing.xs)
        .padding(.vertical, Spacing.m)
        .frame(minHeight: 72)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        // The row's text reads as one element; the trailing action stays its own button.
        .accessibilityElement(children: rowAction == nil ? .combine : .contain)
        .accessibilityAddTraits(onTap != nil && rowAction == nil ? .isButton : [])
    }
}

/// A connection in a list: a ``VettIDListRow`` whose tile turns teal and star turns gold when the connection is a
/// favourite (VAULT-MESSAGING §10.4 `connection.update`). The star toggles it, like Proton's.
/// Mirrors vettid-android `ConnectionRow`.
public struct ConnectionRow: View {
    let name: String
    let favorite: Bool
    let supporting: String?
    let meta: String?
    let emphasized: Bool
    let photo: UIImage?
    let onFavoriteChange: @MainActor (Bool) -> Void
    let onTap: (@MainActor () -> Void)?

    public init(
        name: String,
        favorite: Bool,
        supporting: String? = nil,
        meta: String? = nil,
        emphasized: Bool = false,
        photo: UIImage? = nil,
        onFavoriteChange: @escaping @MainActor (Bool) -> Void,
        onTap: (@MainActor () -> Void)? = nil
    ) {
        self.name = name
        self.favorite = favorite
        self.supporting = supporting
        self.meta = meta
        self.emphasized = emphasized
        self.photo = photo
        self.onFavoriteChange = onFavoriteChange
        self.onTap = onTap
    }

    public var body: some View {
        VettIDListRow(
            title: name,
            supporting: supporting,
            meta: meta,
            tileStyle: favorite ? .favorite : .connection,
            emphasized: emphasized,
            action: RowAction(
                icon: favorite ? .star : .starOutline,
                label: favorite ? UIStrings.favoriteRemove(name) : UIStrings.favoriteAdd(name),
                active: favorite
            ) { onFavoriteChange(!favorite) },
            tilePhoto: photo,
            onTap: onTap
        )
    }
}

/// Outlined content card of a detail screen (Proton message card): the screen's colour, a hairline border, rounded
/// corners. Mirrors vettid-android `DetailCard`.
public struct DetailCard<Content: View>: View {
    @Environment(\.vettIDColors) private var colors
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.background, in: VettIDShape.card)
            .overlay(VettIDShape.card.stroke(colors.outline, lineWidth: 1))
            .padding(.horizontal, Spacing.s)
    }
}

/// Empty state (Proton): one illustration, a title and one line, centred. The illustration is the destination's icon
/// on a raised tile with sparkles. Mirrors vettid-android `EmptyState`.
public struct EmptyState: View {
    @Environment(\.vettIDColors) private var colors
    let icon: VettIDSymbol
    let title: String
    let message: String

    public init(icon: VettIDSymbol, title: String, message: String) {
        self.icon = icon
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            illustration
            Spacer().frame(height: Spacing.xxl)
            Text(title)
                .vettIDFont(.titleMedium, weight: .semibold)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Spacer().frame(height: Spacing.xs)
            Text(message)
                .vettIDFont(.bodyLarge)
                .foregroundStyle(colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
            // Optical centring: Proton sits the block slightly below the middle.
            Spacer().frame(height: Spacing.xxl)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var illustration: some View {
        ZStack {
            Canvas { context, size in
                let sparkle = colors.onSurfaceVariant.opacity(0.7).color
                for (x, y, r) in [(0.14, 0.16, 14.0), (0.84, 0.10, 8.0), (0.90, 0.34, 7.0)] {
                    context.fill(
                        Self.sparkle(center: CGPoint(x: size.width * x, y: size.height * y), radius: r),
                        with: .color(sparkle)
                    )
                }
            }
            icon.image
                .font(.system(size: 44))
                .foregroundStyle(colors.primary)
                .frame(width: 104, height: 104)
                .background(colors.surfaceContainerHigh, in: VettIDShape.tile(104))
                .padding(.top, Spacing.l)
        }
        .frame(width: 160, height: 160)
        .accessibilityHidden(true)
    }

    /// Four-pointed star.
    private static func sparkle(center: CGPoint, radius: CGFloat) -> Path {
        let waist = radius * 0.22
        var p = Path()
        p.move(to: CGPoint(x: center.x, y: center.y - radius))
        p.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: CGPoint(x: center.x + waist, y: center.y - waist))
        p.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: CGPoint(x: center.x + waist, y: center.y + waist))
        p.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: CGPoint(x: center.x - waist, y: center.y + waist))
        p.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: CGPoint(x: center.x - waist, y: center.y - waist))
        p.closeSubpath()
        return p
    }
}
