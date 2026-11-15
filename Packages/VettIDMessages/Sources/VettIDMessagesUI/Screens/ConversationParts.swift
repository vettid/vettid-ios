#if os(iOS)
import SwiftUI
import VettIDData
import VettIDMessages
import VettIDUI

/// The messages by day, oldest at the top, opening at the newest. A new message at the end scrolls to it; an older page
/// added at the top keeps the member's place (VAULT-MESSAGING §10.5.2). Mirrors vettid-android `MessageList`.
struct MessageList: View {
    let state: ConversationState
    let name: String
    let actions: ConversationActions
    @State private var trigger = OlderTrigger()

    /// Which end of the list moved: the first message (only an older page changes it) and the last row.
    struct Edges: Equatable {
        var firstMessage: String?
        var last: String?
    }

    /// What a change of the edges does to the scroll position.
    enum Scroll: Equatable {
        case none
        /// Something was added at the end: show it.
        case toEnd(String)
        /// An older page was added at the top: stay at the message that was first.
        case keep(String)
    }

    /// The first message, not the first row: call lines read after the messages (older than the first message, in a fully loaded
    /// conversation) are not an older page and must not move the member's place. The last row: a call added at the end scrolls to
    /// it, like a message.
    private var edges: Edges { Self.edges(state) }

    static func edges(_ state: ConversationState) -> Edges {
        Edges(firstMessage: state.messages.first?.messageID, last: state.rows.last?.id)
    }

    static func scroll(from old: Edges, to new: Edges) -> Scroll {
        if new.last != old.last, let last = new.last { return .toEnd(last) }
        if new.firstMessage != old.firstMessage, let first = old.firstMessage { return .keep(first) }
        return .none
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if state.olderAvailable { older }
                    if state.callsNotShown { CallsNotShownLine() }
                    ForEach(Self.days(state.rows), id: \.day) { group in
                        DayDivider(MessageTimes.dayLabel(group.day))
                        ForEach(group.rows) { r in row(r).id(r.id) }
                    }
                }
                .padding(.vertical, Spacing.s)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: edges) { old, new in
                switch Self.scroll(from: old, to: new) {
                case .toEnd(let last): withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                case .keep(let first): proxy.scrollTo(first, anchor: .top)
                case .none: break
                }
            }
            .task {
                // Armed once the opening has settled at the newest message: a short conversation that shows its top at
                // once does not load by itself (vettid-android arms on the member's first drag).
                try? await Task.sleep(for: .milliseconds(500))
                trigger.settle()
            }
        }
        .accessibilityIdentifier("messages")
    }

    private var older: some View {
        OlderRow(loading: state.loadingOlder, onLoad: actions.onLoadOlder)
            .onAppear { if trigger.appeared() { actions.onLoadOlder() } }
            .onDisappear { trigger.disappeared() }
    }

    /// A call as its line; a photo message as a photo bubble (VAULT-MESSAGING §10.5.1), any other as text.
    @ViewBuilder private func row(_ r: ConversationRow) -> some View {
        switch r {
        case .call(let c): CallEntry(call: c)
        case .message(let m): message(m)
        }
    }

    @ViewBuilder private func message(_ m: MessageInfo) -> some View {
        if m.attachment != nil {
            PhotoBubble(
                message: m, name: name, generation: state.photoGeneration, actions: actions.photos,
                onDelete: { actions.onAskDelete(m) }
            )
        } else {
            bubble(m)
        }
    }

    private func bubble(_ m: MessageInfo) -> some View {
        let time = MessageTimes.time(m.sentAt)
        let status = Self.status(m)
        return MessageBubble(
            BubbleText.message(m.text),
            outgoing: m.outgoing,
            meta: status.map { "\(time) · \($0)" } ?? time,
            accessibilityLabel: status.map { MessagesStrings.outgoingLabel(AccountNames.cleanedMessage(m.text), time, $0) }
                ?? MessagesStrings.incomingLabel(name, AccountNames.cleanedMessage(m.text), time),
            links: BubbleLinks(name: BubbleText.linkName, open: actions.onLink),
            delete: (label: MessagesStrings.deleteConfirm, action: { actions.onAskDelete(m) })
        )
    }

    /// An outgoing message's state: read, delivered, or sent; nil for an incoming one.
    static func status(_ m: MessageInfo) -> String? {
        guard m.outgoing else { return nil }
        if m.read { return MessagesStrings.statusRead }
        return m.delivered ? MessagesStrings.statusDelivered : MessagesStrings.statusSent
    }

    struct Day {
        let day: Date
        var rows: [ConversationRow]
    }

    /// The rows (messages and calls) grouped by their calendar day, in the order each day first appears, the order of the
    /// rows kept within a day (vettid-android's `groupBy`).
    static func days(_ rows: [ConversationRow], calendar: Calendar = .current) -> [Day] {
        var out: [Day] = []
        var index: [Date: Int] = [:]
        for r in rows {
            let d = calendar.startOfDay(for: r.at)
            if let i = index[d] {
                out[i].rows.append(r)
            } else {
                index[d] = out.count
                out.append(Day(day: d, rows: [r]))
            }
        }
        return out
    }
}

/// When reaching the top loads older messages: not while the conversation is opening, nor for a top that was in view
/// from the start; once the top has gone out of view, every return to it loads (one page at a time, the view model's
/// rule).
struct OlderTrigger: Equatable {
    private(set) var settled = false
    private(set) var armed = false
    private(set) var visible = false

    /// The top came into view: whether to load.
    mutating func appeared() -> Bool {
        visible = true
        return armed
    }

    mutating func disappeared() {
        visible = false
        if settled { armed = true }
    }

    /// The opening settled: armed unless the top is in view already.
    mutating func settle() {
        settled = true
        armed = !visible
    }
}

/// The top of a conversation with older messages in the vault: loading, or a button to load them.
struct OlderRow: View {
    @Environment(\.vettIDColors) private var colors
    let loading: Bool
    let onLoad: @MainActor () -> Void

    var body: some View {
        ZStack {
            if loading {
                ProgressView().tint(colors.primary.color).accessibilityLabel(MessagesStrings.loadingOlder)
            } else {
                Button(action: onLoad) {
                    Text(MessagesStrings.loadOlder).vettIDFont(.labelLarge, weight: .semibold).foregroundStyle(colors.primary)
                        .textButtonTarget()
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.s)
        .accessibilityIdentifier("older")
    }
}

/// A message's text with its tappable links (VAULT-MESSAGING §10.5 "Links", IOS-PLAN §6.8): only the ranges
/// ``MessageLinks`` finds carry a link; everything else, other schemes included, stays plain text.
enum BubbleText {
    /// A link's name for VoiceOver: the host the question shows, lower case and ASCII.
    static func linkName(_ url: URL) -> String { MessageLinks.link(url.absoluteString)?.host ?? "" }

    /// A message's full text for its bubble (VAULT-MESSAGING 0.76.0 §10.8, "more lightly"): cleaned with LRM, RLM and ALM
    /// kept, then each line in its own isolate (FSI … PDI); the links are found in the cleaned text, so a tap opens what the
    /// bubble shows.
    static func message(_ raw: String) -> AttributedString {
        var out = AttributedString()
        let cleaned = AccountNames.cleanedMessage(raw)
        guard !cleaned.isEmpty else { return out }
        for (i, line) in cleaned.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { out += AttributedString("\n") }
            out += AttributedString("\u{2068}") + attributed(String(line)) + AttributedString("\u{2069}")
        }
        return out
    }

    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        var cursor = text.startIndex
        for link in MessageLinks.links(in: text) {
            out += AttributedString(String(text[cursor..<link.range.lowerBound]))
            var piece = AttributedString(String(text[link.range]))
            piece.link = link.url
            piece.underlineStyle = .single
            out += piece
            cursor = link.range.upperBound
        }
        out += AttributedString(String(text[cursor...]))
        return out
    }
}
#endif
