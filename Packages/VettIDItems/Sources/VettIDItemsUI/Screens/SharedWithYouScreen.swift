#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// What the shared-with-you screen can ask for (no-ops by default, for previews and tests). Mirrors vettid-android
/// `SharedWithYouActions`.
public struct SharedWithYouActions {
    public var onBack: @MainActor () -> Void = {}
    public var onRetry: @MainActor () -> Void = {}
    public var onFetch: @MainActor (String) -> Void = { _ in }
    public var onAskGiveUp: @MainActor (GrantView?) -> Void = { _ in }
    public var onGiveUp: @MainActor () -> Void = {}
    public var onDismissError: @MainActor () -> Void = {}
    public var onOpenAsk: @MainActor (Bool) -> Void = { _ in }
    public var onAsk: @MainActor (GrantAskForm) -> Void = { _ in }
    public var onSendAsk: @MainActor () -> Void = {}

    public init() {}
}

/// What a connection shares with the member over its view model, made when the screen first appears (never in `init`, which
/// SwiftUI runs again whenever the shell is redrawn); [ask] opens "Ask for something" at once (from the connection's page).
/// What was fetched is dropped when the app leaves the foreground and when the screen goes (§10.12: kept only while the
/// screen is in front). Mirrors vettid-android `SharedWithYouRouteContent`.
public struct SharedWithYouRoute: View {
    @Environment(\.scenePhase) private var phase
    private let connectionID: String
    private let ask: Bool
    private let sharing: any SharingRepository
    private let items: any ItemsRepository
    private let connections: any ConnectionsRepository
    let host: ItemsHost
    @State private var model: SharedWithYouViewModel?

    public init(
        _ connectionID: String, ask: Bool, sharing: any SharingRepository, items: any ItemsRepository,
        connections: any ConnectionsRepository, host: ItemsHost
    ) {
        self.connectionID = connectionID
        self.ask = ask
        self.sharing = sharing
        self.items = items
        self.connections = connections
        self.host = host
    }

    public var body: some View {
        SharedWithYouScreen(state: model?.state ?? SharedWithYouState(connectionID: connectionID), actions: Self.actions(model, host: host))
            .onChange(of: phase) { _, now in Self.phaseChanged(now, model) }
            .onDisappear { Self.left(model) }
            .onAppear {
                if model == nil {
                    model = SharedWithYouViewModel(
                        connectionID: connectionID, ask: ask, sharing: sharing, items: items, connections: connections
                    )
                }
            }
    }

    /// The screen went (back, or another screen over it): what was fetched goes.
    static func left(_ model: SharedWithYouViewModel?) { model?.hide() }

    /// The app left the foreground: what was fetched goes (Android's `ON_STOP`).
    static func phaseChanged(_ phase: ScenePhase, _ model: SharedWithYouViewModel?) {
        if phase == .background { model?.hide() }
    }

    static func actions(_ m: SharedWithYouViewModel?, host: ItemsHost) -> SharedWithYouActions {
        var a = SharedWithYouActions()
        a.onBack = host.onBack
        guard let m else { return a }
        a.onRetry = { m.load() }
        a.onFetch = { m.fetch($0) }
        a.onAskGiveUp = { m.askGiveUp($0) }
        a.onGiveUp = { m.giveUp() }
        a.onDismissError = { m.dismissError() }
        a.onOpenAsk = { m.openAsk($0) }
        a.onAsk = { m.setAsk($0) }
        a.onSendAsk = { m.sendAsk() }
        return a
    }
}

/// What a connection shares with the member (§10.12 received grants), read-only and labelled as shared by them: the
/// connection's self-asserted data, fetched on purpose and kept only while the screen is in front. Mirrors vettid-android
/// `SharedWithYouScreen`.
public struct SharedWithYouScreen: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDCovered) private var covered
    let state: SharedWithYouState
    let actions: SharedWithYouActions

    public init(state: SharedWithYouState, actions: SharedWithYouActions) {
        self.state = state
        self.actions = actions
    }

    private var name: String { ItemsText.sharingName(state.connectionName) }

    private var askShown: Binding<Bool> {
        Binding(get: { state.ask != nil }, set: { if !$0, state.ask != nil { actions.onOpenAsk(false) } })
    }

    public var body: some View {
        DetailScaffold(onBack: actions.onBack) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LargeTitle(ItemsStrings.sharedTitle(name))
                    Text(ItemsStrings.sharedBody(name))
                        .vettIDFont(.bodyMedium)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .padding(.horizontal, Spacing.gutter)
                    SharingErrorNotice(error: state.error, limit: state.limit, code: state.errorCode, onDismiss: actions.onDismissError)
                    Spacer().frame(height: Spacing.m)
                    if state.loading && state.received.isEmpty {
                        ProgressView().tint(colors.primary.color).frame(maxWidth: .infinity).padding(Spacing.xl)
                    } else if state.received.isEmpty {
                        Text(ItemsStrings.sharedNone(name))
                            .foregroundStyle(colors.onSurfaceVariant)
                            .padding(.horizontal, Spacing.gutter)
                            .accessibilityIdentifier("shared_none")
                    }
                    ForEach(state.received) { g in ReceivedCard(grant: g, state: state, name: name, actions: actions) }
                    AskSection(state: state, name: name, actions: actions)
                }
                .padding(.bottom, Spacing.xxl)
            }
        }
        .accessibilityIdentifier("shared_with_you")
        .sheet(isPresented: uncovered(askShown, covered: covered)) {
            if let form = state.ask {
                AskSheet(form: form, name: name, actions: actions)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(colors.surfaceContainerLow.color)
                    .environment(\.vettIDColors, colors)
            }
        }
        // A cover closes the form being typed, so that it does not come back when the cover lifts.
        .closesWhenCovered { if state.ask != nil { actions.onOpenAsk(false) } }
        .confirmDialog(
            isPresented: Binding(get: { state.confirmGiveUp != nil }, set: { if !$0 { actions.onAskGiveUp(nil) } }),
            title: ItemsStrings.sharedGiveUpTitle(AccountNames.isolateOrNull(state.confirmGiveUp?.name) ?? ItemsStrings.deletedItem),
            message: ItemsStrings.sharedGiveUpBody(name),
            confirmLabel: ItemsStrings.sharedGiveUp, destructive: true, onConfirm: actions.onGiveUp
        )
    }
}

/// A grant received: what it is and whose, what it holds, why a fetch was refused, and the fetched values. Mirrors
/// vettid-android `ReceivedCard`.
struct ReceivedCard: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(ScreenshotAllowance.self) private var allowance: ScreenshotAllowance?
    let grant: GrantView
    let state: SharedWithYouState
    let name: String
    let actions: SharedWithYouActions

    var body: some View {
        let g = grant, id = grant.grantID
        let content = state.opened[id]
        DetailCard {
            Text(AccountNames.isolateOrNull(content?.name ?? g.name) ?? ItemsStrings.deletedItem)
                .vettIDFont(.titleMedium, weight: .semibold)
            Text(ItemsText.receivedLabel(g, category: content?.category, name: name))
                .vettIDFont(.bodySmall)
                .foregroundStyle(colors.onSurfaceVariant)
                .accessibilityIdentifier("received_label_\(id)")
            // What the grant holds, as the connection's vault described it (`grant.list` labels, 0.21.0), before a fetch.
            if content == nil && !g.labels.isEmpty {
                Text(ItemsStrings.sharedHolds(g.labels.compactMap { AccountNames.isolateOrNull($0.label) }.joined(separator: ", ")))
                    .vettIDFont(.bodyMedium)
                    .accessibilityIdentifier("received_fields_\(id)")
            }
            if let why = state.refused[id] {
                Text([ItemsText.refusal(why, name: name), state.retryAt[id].map { ItemsText.retry(until: $0) }]
                    .compactMap { $0 }.joined(separator: " "))
                    .vettIDFont(.bodyMedium)
                    .foregroundStyle(colors.error)
                    .accessibilityIdentifier("received_refused_\(id)")
            }
            if let content {
                Spacer().frame(height: Spacing.s)
                // The connection's values: out of screenshots and recordings unless the member allowed them (IOS-PLAN §6.4).
                SecureContainer(isSecure: !(allowance?.allowed ?? false)) { SharedFields(content: content) }
            } else if g.active {
                Button { actions.onFetch(id) } label: {
                    Text(state.fetching == id ? ItemsStrings.sharedFetching : ItemsStrings.sharedFetch)
                        .vettIDFont(.labelLarge)
                        .foregroundStyle(state.fetching == nil ? colors.primary : colors.onSurfaceVariant)
                        .frame(minHeight: Spacing.touchTarget)
                }
                .buttonStyle(.plain)
                .disabled(state.fetching != nil)
                .accessibilityIdentifier("fetch_\(id)")
            } else {
                Text(ItemsStrings.sharedEnded).foregroundStyle(colors.onSurfaceVariant)
            }
            if g.active {
                Button { actions.onAskGiveUp(g) } label: {
                    Text(ItemsStrings.sharedGiveUp)
                        .vettIDFont(.labelLarge)
                        .foregroundStyle(colors.error)
                        .frame(minHeight: Spacing.touchTarget)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("give_up_\(id)")
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("received_\(id)")
    }
}

/// The fetched fields and notes, read-only. A phone number is shown formatted for the iPhone's region, as the member's own
/// are (vettid-android #95).
struct SharedFields: View {
    @Environment(\.vettIDColors) private var colors
    let content: SharedContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(content.fields.enumerated()), id: \.offset) { _, f in
                // An empty label is left out, not shown as a blank line (VAULT-MESSAGING 0.76.0 §10.8 step 4).
                if let label = AccountNames.cleaned(f.label) {
                    Text(label).vettIDFont(.labelMedium).foregroundStyle(colors.onSurfaceVariant)
                }
                let text = Self.text(f)
                Text(text.isEmpty ? ItemsStrings.emptyValue : text)
                    .vettIDFont(.bodyLarge)
                    .padding(.bottom, Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notes = AccountNames.cleanedLines(content.notes) {
                Text(ItemsStrings.notes).vettIDFont(.labelMedium)
                Text(notes).vettIDFont(.bodyLarge).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A field's value as shown, cleaned (VAULT-MESSAGING 0.76.0 §10.8): one line, except a multi-line field and an address,
    /// whose lines are kept (chosen; not in the spec). "" when nothing shows.
    static func text(_ f: ItemFieldView) -> String {
        switch f.value {
        case .text(let t)?:
            if f.kind == FieldKinds.multiline { return AccountNames.cleanedLines(t) ?? "" }
            let one = AccountNames.cleaned(t) ?? ""
            return f.kind == FieldKinds.phone ? PhoneInput.display(one) : one
        case .address(let a)?: return AccountNames.cleanedLines(a.lines.joined(separator: "\n")) ?? ""
        case nil: return ""
        }
    }
}

/// What the member asked this connection for (§10.12), and "Ask for something". Mirrors vettid-android `AskSection`.
struct AskSection: View {
    let state: SharedWithYouState
    let name: String
    let actions: SharedWithYouActions

    var body: some View {
        SettingsSectionHeader(ItemsStrings.askTitle)
        if state.asked {
            Text(ItemsStrings.askSent(name)).padding(.horizontal, Spacing.gutter).accessibilityIdentifier("ask_sent")
        }
        ForEach(state.requested) { r in
            let entries = r.entries.map(ItemsText.askEntry).joined(separator: ", ")
            Text(ItemsStrings.askRow(entries.isEmpty ? "?" : entries, ItemsText.askState(r.state)))
                .vettIDFont(.bodyMedium)
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, Spacing.xs)
        }
        SecondaryButton(ItemsStrings.askButton(name)) { actions.onOpenAsk(true) }
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.s)
            .accessibilityIdentifier("ask_open")
    }
}

/// "Ask <name> for something": a category, a label and a reason (typed as the member's own words; a label of at most 128
/// bytes and a reason of at most 256, §10.12). Mirrors vettid-android `AskDialog`.
struct AskSheet: View {
    @Environment(\.vettIDColors) private var colors
    let form: GrantAskForm
    let name: String
    let actions: SharedWithYouActions

    var body: some View {
        DialogSheet(
            title: ItemsStrings.askButton(name), confirm: ItemsStrings.askSend, enabled: !form.busy, confirmID: "ask_send",
            onCancel: { actions.onOpenAsk(false) }, onConfirm: actions.onSendAsk
        ) {
            Menu {
                ForEach(ItemTemplates.categories) { c in
                    Button { var f = form; f.category = c.id; actions.onAsk(f) } label: {
                        Label(c.label, systemImage: ItemSymbols.category(c.id).rawValue)
                    }
                }
            } label: {
                MenuField(text: ItemsStrings.askCategory(ItemsText.category(form.category)))
            }
            .accessibilityLabel(ItemsStrings.askCategory(ItemsText.category(form.category)))
            .accessibilityIdentifier("ask_category")
            OutlinedInput(caption: ItemsStrings.askLabel, supporting: nil) {
                CappedField(text: form.label, cap: Utf8Cap.label) { var f = form; f.label = $0; actions.onAsk(f) }
                    .accessibilityLabel(ItemsStrings.askLabel)
                    .accessibilityIdentifier("ask_label")
            }
            OutlinedInput(caption: ItemsStrings.askReason, supporting: nil) {
                CappedField(text: form.reason, cap: Utf8Cap.reason, lines: 2...5) { var f = form; f.reason = $0; actions.onAsk(f) }
                    .accessibilityLabel(ItemsStrings.askReason)
                    .accessibilityIdentifier("ask_reason")
            }
            Text(ItemsStrings.askNote(name)).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
        }
        .accessibilityIdentifier("ask_sheet")
    }
}

/// A text field that stops at a size: what is typed or pasted beyond [cap] is cut at once, whole characters only. The
/// typed text is held here and cut after it is set (a cut that gives the text the field already shows would not redraw it).
struct CappedField: View {
    let text: String
    let cap: (String) -> String
    let onChange: @MainActor (String) -> Void
    /// More than one line: the field grows over these lines (Android's reason field); nil: one line.
    let lines: ClosedRange<Int>?
    @State private var typed: String

    init(
        text: String, cap: @escaping (String) -> String, lines: ClosedRange<Int>? = nil, onChange: @escaping @MainActor (String) -> Void
    ) {
        self.text = text
        self.lines = lines
        self.cap = cap
        self.onChange = onChange
        _typed = State(initialValue: text)
    }

    var body: some View {
        PlainField(placeholder: nil, text: typed, lines: lines) { typed = $0 }
            .textInputAutocapitalization(.sentences)
            .onChange(of: typed) { _, now in
                let kept = cap(now)
                if kept != now { typed = kept } else if kept != text { onChange(kept) }
            }
            .onChange(of: text) { _, now in if now != typed { typed = now } }
    }
}
#endif
