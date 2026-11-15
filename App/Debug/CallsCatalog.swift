#if DEBUG
import SwiftUI
import VettIDCalls
import VettIDCallsUI
import VettIDData
import VettIDMessages
import VettIDMessagesUI
import VettIDUI

/// Debug only: every state of the call screen and the microphone gate's two dialogs, with sample data, for the screen catalog and
/// the previews. Fixed states with actions that do nothing. The release check refuses its strings.
enum CallsCatalog {
    struct Entry: Identifiable, Sendable {
        let id: String
        let title: String
        let screen: Screen
    }

    enum Screen: Sendable {
        case call(CallUiState)
        case microphone(blocked: Bool)
        /// A conversation with call lines (its Call action shown or not).
        case conversation(ConversationState)
    }

    /// A conversation with Ada: a message before and after calls of every outcome, the note for calls that did not read, and the
    /// one for a history that could not be checked.
    static func conversation(availability: ConversationCallAvailability, notShown: Bool, outOfDate: Bool = false) -> ConversationState {
        var c = ConnectionInfo(id: "c1", name: "", state: .active)
        c.firstName = "Ada"
        c.lastName = "Lovelace"
        func message(_ id: String, _ text: String, outgoing: Bool, at: TimeInterval) -> MessageInfo {
            MessageInfo(
                connectionID: "c1", messageID: id, outgoing: outgoing, text: text, sentAt: since.addingTimeInterval(at), delivered: true,
                read: true
            )
        }
        func call(_ id: String, _ outcome: ConversationCallOutcome, at: TimeInterval, outgoing: Bool, duration: TimeInterval? = nil)
            -> ConversationCall {
            ConversationCall(callId: id, outgoing: outgoing, outcome: outcome, startedAt: since.addingTimeInterval(at), duration: duration)
        }
        var s = ConversationState(connectionID: "c1")
        s.loading = false
        s.connection = c
        s.messages = [
            message("m1", "Are you free to talk?", outgoing: true, at: 0), message("m2", "Calling you now", outgoing: false, at: 3_000),
        ]
        s.calls = [
            call("k1", .talked, at: 60, outgoing: true, duration: 252), call("k2", .talked, at: 120, outgoing: false, duration: 3_840),
            call("k3", .talked, at: 180, outgoing: true, duration: 12), call("k4", .declined, at: 240, outgoing: true),
            call("k5", .declinedHere, at: 300, outgoing: false), call("k6", .busy, at: 360, outgoing: true),
            call("k7", .notAnswered, at: 420, outgoing: true), call("k8", .missed, at: 480, outgoing: false),
            call("k9", .failed, at: 540, outgoing: true),
        ]
        s.callsNotShown = notShown
        s.callsOutOfDate = outOfDate
        s.callAvailability = availability
        return s
    }

    static let since = Date(timeIntervalSince1970: 1_791_384_000)

    private static func live(
        _ phase: CallPhase, muted: Bool = false, reconnecting: Bool = false, seconds: TimeInterval? = nil, speaker: Bool = false
    ) -> CallUiState {
        CallUiState(
            call: .live(CallState.Live(
                connectionId: "c1", direction: phase == .incoming ? .incoming : .outgoing, phase: phase, muted: muted,
                activeSince: seconds.map { since.addingTimeInterval(-$0) }, reconnecting: reconnecting
            )),
            name: "Ada Lovelace", firstName: "Ada", speaker: speaker, canSpeaker: true
        )
    }

    private static func ended(_ reason: CallEnd) -> CallUiState {
        CallUiState(
            call: .ended(CallState.Ended(connectionId: "c1", direction: .outgoing, reason: reason)), name: "Ada Lovelace", firstName: "Ada"
        )
    }

    static let entries: [Entry] = {
        var all: [Entry] = []
        func add(_ id: String, _ title: String, _ state: CallUiState) { all.append(Entry(id: id, title: title, screen: .call(state))) }
        add("incoming", "Incoming: Answer and Decline", live(.incoming))
        add("calling", "Outgoing: Calling…", live(.calling))
        add("ringing", "Outgoing: Ringing…", live(.ringing))
        add("connecting", "Connecting…", live(.connecting))
        add("active", "Active: 4:12", live(.active, seconds: 252))
        add("active_hour", "Active: 1:04:12, muted, speaker", live(.active, muted: true, seconds: 3852, speaker: true))
        add("reconnecting", "Active: Reconnecting…", live(.active, reconnecting: true, seconds: 252))
        // The endings that keep the screen until Close, then one of those that close at once (it is never on screen).
        for reason in CallEnd.allCases where CallTexts.staysOpen(reason) {
            add("ended_\(reason)", "Ended: \(reason)", ended(reason))
        }
        all.append(Entry(id: "microphone_explain", title: "Microphone: explain", screen: .microphone(blocked: false)))
        all.append(Entry(id: "microphone_blocked", title: "Microphone: blocked", screen: .microphone(blocked: true)))
        all.append(Entry(
            id: "conversation_calls", title: "Conversation: calls of each outcome, Call action, note",
            screen: .conversation(conversation(availability: .ready, notShown: true, outOfDate: true))
        ))
        all.append(Entry(
            id: "conversation_in_call", title: "Conversation: during a call (no Call action)",
            screen: .conversation(conversation(availability: .inCall, notShown: false))
        ))
        return all
    }()

    /// The screen for [entry], with actions that do nothing.
    @MainActor @ViewBuilder
    static func screen(_ entry: Entry) -> some View {
        switch entry.screen {
        case .call(let state):
            CallScreen(state, actions: CallActions(), now: { since })
        case .microphone(let blocked):
            MicrophoneCatalogView(blocked: blocked)
        case .conversation(let state):
            ConversationScreen(state: state, actions: conversationActions)
        }
    }

    private static var conversationActions: ConversationActions {
        var a = ConversationActions()
        a.onCall = {}
        return a
    }
}

/// The microphone gate's dialog as the calls window shows it, over nothing.
private struct MicrophoneCatalogView: View {
    let blocked: Bool
    @Environment(\.vettIDColors) private var colors
    @State private var shown = true

    var body: some View {
        colors.background.color.ignoresSafeArea()
            .confirmDialog(
                isPresented: $shown,
                title: blocked ? CallStrings.microphoneBlockedTitle : CallStrings.microphoneTitle,
                message: blocked ? CallStrings.microphoneBlockedBody : CallStrings.microphoneBody("\u{2068}Ada\u{2069}"),
                confirmLabel: blocked ? CallStrings.microphoneOpenSettings : CallStrings.microphoneAllow,
                dismissLabel: blocked ? CallStrings.microphoneClose : CallStrings.microphoneNotNow, onConfirm: {}
            )
    }
}

/// Debug-only: the call screens (``CallsCatalog``). Opened from the screen catalog, or at launch with `-vettid.start calls`.
struct CallsCatalogScreen: View {
    let onBack: @MainActor () -> Void
    @State private var shown: String?

    var body: some View {
        DetailScaffold(onBack: onBack) {
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle("Calls")
                    SettingsGroup {
                        ForEach(CallsCatalog.entries) { entry in
                            SettingsRow(entry.title) { shown = entry.id }
                                .accessibilityIdentifier("catalog_calls_\(entry.id)")
                        }
                    }
                }
            }
        }
        .navigationDestination(item: $shown) { id in
            if let entry = CallsCatalog.entries.first(where: { $0.id == id }) {
                CallsCatalog.screen(entry)
                    // A conversation has its own top bar: the catalog's way back goes above its composer instead.
                    .overlay(alignment: entry.id.hasPrefix("conversation") ? .bottomTrailing : .topTrailing) {
                        IconButton(.close, label: "Close catalog") { shown = nil }.padding(.horizontal, Spacing.xs)
                            .padding(.bottom, entry.id.hasPrefix("conversation") ? 88 : 0)
                            .accessibilityIdentifier("catalog_calls_back")
                    }
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}

#Preview("Call screens") {
    TabView {
        ForEach(CallsCatalog.entries) { entry in
            CallsCatalog.screen(entry).tabItem { Text(verbatim: entry.title) }
        }
    }
    .tabViewStyle(.page)
    .vettIDTheme(.dark)
}
#endif
