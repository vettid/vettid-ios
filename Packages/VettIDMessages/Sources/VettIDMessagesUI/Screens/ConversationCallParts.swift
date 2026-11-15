#if os(iOS)
import SwiftUI
import VettIDMessages
import VettIDUI

/// "Some calls couldn't be shown.": one short line above the rows, in every conversation while the vault's call list had entries
/// that did not read (owner decision, Ground Control #10659 a). Mirrors vettid-android `CallsNotShownLine`.
struct CallsNotShownLine: View {
    @Environment(\.vettIDColors) private var colors

    var body: some View {
        Text(MessagesStrings.callsNotShown)
            .vettIDFont(.bodySmall)
            .foregroundStyle(colors.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.xs)
            .accessibilityIdentifier("calls_not_shown")
    }
}

/// A call in the conversation: what became of it, and when (the vault's history; no content). Mirrors vettid-android
/// `CallEntry`.
struct CallEntry: View {
    @Environment(\.vettIDColors) private var colors
    let call: ConversationCall

    /// The line's text: the outcome, then the time.
    static func text(_ call: ConversationCall) -> String { "\(MessagesStrings.callLine(call)) · \(MessageTimes.time(call.startedAt))" }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            // SF Symbols' phone arrows do not mirror by themselves; Android's are auto-mirrored.
            (call.outgoing ? VettIDSymbol.callMade : VettIDSymbol.callReceived).image
                .flipsForRightToLeftLayoutDirection(true)
                .scaledIcon(size: 16)
                .foregroundStyle(colors.onSurfaceVariant)
                .accessibilityHidden(true)
            Text(Self.text(call)).vettIDFont(.labelMedium).foregroundStyle(colors.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.s)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation_call_entry")
    }
}
#endif
