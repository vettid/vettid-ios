#if os(iOS)
import SwiftUI
import VettIDData
import VettIDMessages
import VettIDUI

/// VoiceOver is told of each message that arrives while the conversation is on screen: "<name>: <text>", or the photo's
/// label (chosen; not in the spec; I4 audit, accessibility). Never the member's own messages, never what the opening load
/// brings, never a page of older messages. Nothing is said while the conversation cannot be seen: the app in the
/// background or inactive, the app lock or a full cover over the app, a screen or the photo cover over the conversation.
struct AnnouncesArrivals: ViewModifier {
    let state: ConversationState
    let name: String
    /// Something covers the conversation (the camera, the prepared photos).
    let covered: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.vettIDCovered) private var appCovered
    @Environment(\.vettIDLocked) private var locked
    @State private var visible = false
    /// Messages were shown since the opening load: an empty list after them is a clear (a lock, a reload), and the page
    /// that comes back is not news.
    @State private var hadMessages = false

    /// The most messages said in one announcement: the newest ones.
    static let most = 3

    /// What changes when messages arrive: the opening load's end and the messages' ids.
    struct Key: Equatable {
        var loading: Bool
        var ids: [String]
    }

    private var key: Key { Key(loading: state.loading, ids: state.messages.map(\.messageID)) }

    func body(content: Content) -> some View {
        content
            .onAppear {
                visible = true
                if !state.messages.isEmpty { hadMessages = true }
            }
            .onDisappear { visible = false }
            .onChange(of: key) { old, _ in
                defer { if !state.messages.isEmpty { hadMessages = true } }
                guard visible, !covered, !appCovered, !locked, scenePhase == .active else { return }
                let arrived = Self.arrivals(after: old, in: state.messages, hadMessages: hadMessages)
                guard !arrived.isEmpty else { return }
                // Several at once (a reconnect) are one announcement, oldest first: separate ones would cut each other off.
                Announcer.announce(arrived.map { Self.spoken($0, name) }.joined(separator: "\n"))
            }
    }

    /// The incoming messages that came after the last one of [old], the newest ``most`` of them. None while [old] was the
    /// opening load; when [old] was empty, every incoming one only if the conversation has been empty since its load
    /// ([hadMessages] false: its first message), none after a clear; none when [old]'s last message is gone (a delete, a
    /// reload), as what follows it cannot be told from what was there.
    static func arrivals(after old: Key, in messages: [MessageInfo], hadMessages: Bool) -> [MessageInfo] {
        guard !old.loading else { return [] }
        let start: Int
        if let last = old.ids.last {
            guard let i = messages.firstIndex(where: { $0.messageID == last }) else { return [] }
            start = i + 1
        } else {
            guard !hadMessages else { return [] }
            start = 0
        }
        let known = Set(old.ids)
        return Array(messages[start...].filter { !$0.outgoing && !known.contains($0.messageID) }.suffix(most))
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
