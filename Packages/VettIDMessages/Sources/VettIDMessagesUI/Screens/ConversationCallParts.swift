#if os(iOS)
import SwiftUI
import VettIDMessages
import VettIDUI

/// "Some calls couldn't be shown.": one short line above the rows, in every conversation while the vault's call list had entries
/// that did not read (owner decision, Ground Control #10659 a). Mirrors vettid-android `CallsNotShownLine`.
struct CallsNotShownLine: View {
    @Environment(\.vettIDColors) private var colors

    var body: some View {
        CallsNote(text: MessagesStrings.callsNotShown).accessibilityIdentifier("calls_not_shown")
    }
}

/// "Calls may be out of date.": the list's last line, where the newest call would be (the list opens there; the same on both
/// apps).
struct CallsOutOfDateLine: View {
    var body: some View {
        CallsNote(text: MessagesStrings.callsOutOfDate).accessibilityIdentifier("calls_out_of_date")
    }
}

/// A note about the calls, as a line of the list.
private struct CallsNote: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    var body: some View {
        Text(text)
            .vettIDFont(.bodySmall)
            .foregroundStyle(colors.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.xs)
    }
}

/// A call in the conversation: what became of it, and when (the vault's history; no content). Mirrors vettid-android
/// `CallEntry`.
struct CallEntry: View {
    @Environment(\.vettIDColors) private var colors
    let call: ConversationCall

    /// The line's text: the outcome, then the time.
    static func text(_ call: ConversationCall) -> String { "\(MessagesStrings.callLine(call)) · \(MessageTimes.time(call.startedAt))" }

    /// The direction's arrow, mirrored right to left. SF Symbols' phone arrows do not mirror by themselves (a test renders them
    /// both ways); Android's are auto-mirrored.
    static func arrow(outgoing: Bool) -> some View {
        (outgoing ? VettIDSymbol.callMade : VettIDSymbol.callReceived).image.flipsForRightToLeftLayoutDirection(true)
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Self.arrow(outgoing: call.outgoing)
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
