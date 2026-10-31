#if os(iOS)
import SwiftUI
import VettIDData
import VettIDMessages
import VettIDUI

/// VoiceOver is told of each message that arrives while the conversation is on screen: "<name>: <text>", or the photo's
/// label (chosen; not in the spec; I4 audit, accessibility). Never the member's own messages, never what the opening load
/// brings, never a page of older messages, and not while a screen or the photo cover is over the conversation.
struct AnnouncesArrivals: ViewModifier {
    let state: ConversationState
    let name: String
    /// Something covers the conversation (the camera, the prepared photos).
    let covered: Bool
    @State private var visible = false

    /// What changes when messages arrive: the opening load's end and the messages' ids.
    struct Key: Equatable {
        var loading: Bool
        var ids: [String]
    }

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .onChange(of: Key(loading: state.loading, ids: state.messages.map(\.messageID))) { old, _ in
                guard visible, !covered else { return }
                let arrived = Self.arrivals(after: old, in: state.messages)
                guard !arrived.isEmpty else { return }
                // Several at once (the app back in the foreground) are one announcement, oldest first: separate ones would
                // cut each other off.
                Announcer.announce(arrived.map { Self.spoken($0, name) }.joined(separator: "\n"))
            }
    }

    /// The incoming messages that came after the last one of [old]. None while [old] was the opening load; every incoming
    /// one when [old] was a loaded, empty conversation; none when [old]'s last message is gone (a delete, a reload), as
    /// what follows it cannot be told from what was there.
    static func arrivals(after old: Key, in messages: [MessageInfo]) -> [MessageInfo] {
        guard !old.loading else { return [] }
        let start: Int
        if let last = old.ids.last {
            guard let i = messages.firstIndex(where: { $0.messageID == last }) else { return [] }
            start = i + 1
        } else {
            start = 0
        }
        let known = Set(old.ids)
        return messages[start...].filter { !$0.outgoing && !known.contains($0.messageID) }
    }

    /// What VoiceOver says for [m]: the sender and the text, or the photo bubble's label.
    static func spoken(_ m: MessageInfo, _ name: String) -> String {
        let text = AccountNames.cleanedMessage(m.text)
        if m.attachment != nil { return photoLabel(MessagesStrings.photoCdIn(name), text, nil) }
        return MessagesStrings.iosArrived(name, text)
    }
}

extension View {
    func announcesArrivals(_ state: ConversationState, name: String, covered: Bool) -> some View {
        modifier(AnnouncesArrivals(state: state, name: name, covered: covered))
    }
}
#endif
