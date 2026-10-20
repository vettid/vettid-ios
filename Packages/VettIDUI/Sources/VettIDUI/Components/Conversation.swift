import SwiftUI

/// One message in a conversation (ANDROID-PLAN §4): the member's own messages on the right in a gold fill, the
/// connection's on the left in a card colour. [meta] is the time and, for own messages, the delivery state; the whole
/// bubble reads as one item ([accessibilityLabel]). Mirrors vettid-android `MessageBubble`.
///
/// [text] may carry `.link` runs (the message's tappable links, VAULT-MESSAGING §10.5 "Links"): a tap on one is handed
/// to [links] and never opened by the system here; VoiceOver offers each link as an action named by [links]' name for
/// it. With [delete], the bubble's context menu (a long press) offers the delete.
public struct MessageBubble: View {
    @Environment(\.vettIDColors) private var colors
    let text: AttributedString
    let outgoing: Bool
    let meta: String
    let accessibilityText: String
    let links: BubbleLinks?
    let deleteLabel: String?
    let onDelete: (@MainActor () -> Void)?

    public init(_ text: String, outgoing: Bool, meta: String, accessibilityLabel: String) {
        self.init(AttributedString(text), outgoing: outgoing, meta: meta, accessibilityLabel: accessibilityLabel)
    }

    public init(
        _ text: AttributedString,
        outgoing: Bool,
        meta: String,
        accessibilityLabel: String,
        links: BubbleLinks? = nil,
        delete: (label: String, action: @MainActor () -> Void)? = nil
    ) {
        self.text = text
        self.outgoing = outgoing
        self.meta = meta
        self.accessibilityText = accessibilityLabel
        self.links = links
        self.deleteLabel = delete?.label
        self.onDelete = delete?.action
    }

    /// The link runs of [text], in order.
    static func linkURLs(_ text: AttributedString) -> [URL] { text.runs.compactMap(\.link) }

    public var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: outgoing ? 18 : 4,
            bottomTrailingRadius: outgoing ? 4 : 18,
            topTrailingRadius: 18,
            style: .continuous
        )
        let ink = outgoing ? colors.onPrimaryContainer : colors.onSurface
        let metaInk = (outgoing ? colors.onPrimaryContainer : colors.onSurfaceVariant).opacity(0.8)
        HStack(spacing: 0) {
            if outgoing { Spacer(minLength: 0) }
            HStack(spacing: 0) {
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    Text(text).vettIDFont(.bodyLarge).foregroundStyle(ink).multilineTextAlignment(.leading)
                        .tint(ink)
                    Text(meta).vettIDFont(.labelSmall).foregroundStyle(metaInk)
                }
                .padding(.horizontal, Spacing.m + Spacing.xxs)
                .padding(.vertical, Spacing.s)
                .background(outgoing ? colors.primaryContainer : colors.surfaceContainerHigh, in: shape)
                // A link is the caller's to open, after its question: never the system's from here.
                .environment(\.openURL, BubbleLinks.intercepting(links))
                .contentShape(.contextMenuPreview, shape)
                .contextMenu { deleteMenu }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
                .accessibilityActions { linkActions }
            }
            // The bubble hugs its text, up to 78 % of the row.
            .containerRelativeFrame(.horizontal, alignment: outgoing ? .trailing : .leading) { width, _ in
                (width - 2 * Spacing.gutter) * 0.78
            }
            if !outgoing { Spacer(minLength: 0) }
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.xxs)
    }

    @ViewBuilder private var deleteMenu: some View {
        if let deleteLabel, let onDelete {
            Button(role: .destructive, action: onDelete) { Label(deleteLabel, systemImage: VettIDSymbol.delete.rawValue) }
        }
    }

    @ViewBuilder private var linkActions: some View {
        if let deleteLabel, let onDelete { Button(deleteLabel, action: onDelete) }
        if let links {
            ForEach(Array(Self.linkURLs(text).enumerated()), id: \.offset) { _, url in
                Button(links.name(url)) { links.open(url) }
            }
        }
    }
}

/// What a bubble does with its links: [open] takes a tapped link (the caller asks before anything opens), [name] names a
/// link for VoiceOver (the host the caller's question shows).
public struct BubbleLinks {
    public let name: @MainActor (URL) -> String
    public let open: @MainActor (URL) -> Void

    public init(name: @escaping @MainActor (URL) -> String, open: @escaping @MainActor (URL) -> Void) {
        self.name = name
        self.open = open
    }

    /// The bubble's `openURL`: every link goes to [links] (or nowhere), never to the system.
    public static func intercepting(_ links: BubbleLinks?) -> OpenURLAction {
        OpenURLAction { url in
            MainActor.assumeIsolated { links?.open(url) }
            return .handled
        }
    }
}

/// A day separator in a conversation. Mirrors vettid-android `DayDivider`.
public struct DayDivider: View {
    @Environment(\.vettIDColors) private var colors
    let label: String

    public init(_ label: String) { self.label = label }

    public var body: some View {
        Text(label)
            .vettIDFont(.labelMedium)
            .foregroundStyle(colors.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.m)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The 6-digit safety code (VAULT-MESSAGING §6.3 SAS) in two groups of three, large and monospaced; screen readers
/// hear the digits one by one. Mirrors vettid-android `SafetyCode`.
public struct SafetyCode: View {
    @Environment(\.vettIDColors) private var colors
    let digits: String

    public init(_ code: String) { digits = code.filter(\.isNumber) }

    public var body: some View {
        HStack(spacing: Spacing.l) {
            ForEach(Array(Self.groups(digits).enumerated()), id: \.offset) { _, group in
                Text(verbatim: group)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(colors.primary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UIStrings.safetyCode(digits.map(String.init).joined(separator: " ")))
    }

    static func groups(_ digits: String) -> [String] {
        stride(from: 0, to: digits.count, by: 3).map { i in
            let start = digits.index(digits.startIndex, offsetBy: i)
            let end = digits.index(start, offsetBy: min(3, digits.count - i))
            return String(digits[start..<end])
        }
    }
}
