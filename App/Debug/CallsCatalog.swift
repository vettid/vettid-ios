#if DEBUG
import SwiftUI
import VettIDCalls
import VettIDCallsUI
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
        }
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
                    .overlay(alignment: .topTrailing) {
                        IconButton(.close, label: "Close catalog") { shown = nil }.padding(.horizontal, Spacing.xs)
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
