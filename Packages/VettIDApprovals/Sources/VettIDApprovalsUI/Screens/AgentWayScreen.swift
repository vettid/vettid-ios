#if os(iOS)
import SwiftUI
import UIKit
import VettIDApprovals
import VettIDData
import VettIDDevices
import VettIDDevicesUI
import VettIDUI

/// An agent's run or proxy held for approval (ANDROID-PLAN 0.1.137 AA8): everything the vault holds, each string by the string rule
/// in its own box, the flags' warnings at the top and again at the end, **Approve** only once the content was scrolled to its end
/// (any way of scrolling counts: touch, VoiceOver's and Switch Control's scroll actions, a hardware keyboard), and the disabled
/// Approve's hint "Scroll to the end to approve.". **Deny** and scrolling always work. iOS lets no other app draw over this
/// window or take its touches, so there is no overlay rule here (IOS-PLAN §4.21). Mirrors vettid-android `AgentWayScreen`.
struct AgentWayScreen: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let state: ApprovalDetailState
    let request: DeviceRequest
    let show: HeldShow
    let actions: DecisionActions
    let now: Date
    /// The request ended while the screen was open: its text, no buttons (AA8 "Refused or expired").
    var expired = false
    /// Told whenever the gate changes (a test's seam: the screen's tree is not readable without VoiceOver on).
    var onGate: (Bool) -> Void = { _ in }

    @State private var gate: WayGate
    @State private var endY: Double?

    init(state: ApprovalDetailState, request: DeviceRequest, show: HeldShow, actions: DecisionActions, now: Date, expired: Bool = false) {
        self.state = state
        self.request = request
        self.show = show
        self.actions = actions
        self.now = now
        self.expired = expired
        _gate = State(initialValue: WayGate(key: Self.contentKey(state, show)))
    }

    /// The gate re-arms when what is shown changes (not by the member's own taps), and on a new opening; a rotation keeps it.
    static func contentKey(_ state: ApprovalDetailState, _ show: HeldShow) -> String { "\(state.key):\(WayKey.of(show))" }

    private var rows: [WayRow] {
        let a = PendingApproval.device(request)
        return WayRows.rows(
            show, who: ApprovalTexts.deviceSentenceStart(a), whoInline: ApprovalTexts.deviceSentenceInline(a), expired: expired
        )
    }

    /// At the largest Dynamic Type sizes the hint moves above the buttons, and the scroll area keeps at least ``minScroll`` pt.
    private var large: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        let key = Self.contentKey(state, show)
        DetailScaffold(onBack: actions.onBack) {
            GeometryReader { total in
                VStack(spacing: 0) {
                    scrolled
                    if !expired { panel(linesMax: max(0, total.size.height - Self.minScroll - Self.minPanel)) }
                }
            }
        }
        .onChange(of: gate.reached, initial: true) { _, reached in onGate(reached) }
        .onChange(of: key) { _, new in
            gate.rearm(new)
            // Laid out again, the new content is judged from its own geometry.
            Task { @MainActor in gate.rejudge() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent_way")
    }

    // MARK: The content

    private var scrolled: some View {
        // The scrolled area's own height is read here, with the geometry of its end, so that both are of the same layout pass.
        GeometryReader { area in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Color.clear.frame(height: 0).id("way_top")
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                ForEach(Array(row.parts.enumerated()), id: \.offset) { _, part in WayPartView(part: part) }
                            }
                            .padding(.horizontal, Spacing.gutter)
                        }
                        // The end: the bottom edge of the last element, in the scrolled area's own coordinates.
                        Color.clear.frame(height: 1)
                            .accessibilityHidden(true)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: WayEndKey.self, value: g.frame(in: .named("way_scroll")).maxY)
                            })
                    }
                }
                .coordinateSpace(name: "way_scroll")
                .onPreferenceChange(WayEndKey.self) { end in
                    MainActor.assumeIsolated {
                        endY = end
                        gate.update(end: end, viewport: area.size.height)
                    }
                }
                .onChange(of: area.size.height) { _, height in gate.update(end: endY, viewport: height) }
                .onChange(of: Self.contentKey(state, show)) { _, _ in proxy.scrollTo("way_top", anchor: .top) }
            }
        }
        .frame(minHeight: Self.minScroll)
        .accessibilityIdentifier("agent_way_content")
    }

    // MARK: The buttons

    private func panel(linesMax: CGFloat) -> some View {
        let enabled = gate.reached && state.canApprove(at: now) && !state.busy
        return VStack(spacing: Spacing.s) {
            // The text lines give way to the scroll area; the buttons never do.
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    if let error = state.error {
                        let text = ApprovalTexts.failure(error, retryUntil: state.retryUntil, limit: state.limit, now: now)
                        WayLine(text: text, warning: true).announcedOnce(text, .assertive).accessibilityIdentifier("failure")
                    }
                    if !gate.reached && large { hint }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: linesMax)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.s) {
                SecondaryButton(ApprovalsStrings.deny, action: actions.onDeny)
                    .disabled(state.busy)
                    .accessibilityIdentifier("agent_way_deny")
                PrimaryButton(ApprovalsStrings.approve, busy: state.busy, action: actions.onApprove)
                    .disabled(!enabled)
                    // What VoiceOver says of the disabled button: why it is.
                    .accessibilityHint(gate.reached ? "" : ApprovalsStrings.wayScrollHint)
                    .accessibilityIdentifier("agent_way_approve")
            }
            if !gate.reached && !large { hint }
        }
        .padding(Spacing.gutter)
    }

    private var hint: some View { WayLine(text: ApprovalsStrings.wayScrollHint).accessibilityIdentifier("agent_way_hint") }

    /// The least height the scrolled content keeps (AA8, at the largest Dynamic Type size).
    static let minScroll: CGFloat = 120
    /// What the button row and its padding take, kept out of the lines' share.
    static let minPanel: CGFloat = 96
}

private struct WayEndKey: PreferenceKey {
    static let defaultValue: Double? = nil
    static func reduce(value: inout Double?, nextValue: () -> Double?) { value = nextValue() ?? value }
}

/// One part of a row.
private struct WayPartView: View {
    @Environment(\.vettIDColors) private var colors
    let part: WayPart

    var body: some View {
        switch part {
        case .title(let t):
            Text(t).vettIDFont(.headlineSmall).accessibilityAddTraits(.isHeader).accessibilityIdentifier("agent_way_title")
        case .heading(let t):
            Text(t).vettIDFont(.titleSmall).accessibilityAddTraits(.isHeader).padding(.top, Spacing.s)
        case .line(let text, let tag, let warning, let mono, let stress):
            WayLine(text: text, warning: warning, mono: mono, stress: stress).accessibilityIdentifier(tag)
        case .box(let s, let tag):
            ShownStringBox(s, identifier: tag)
        case .pin(let sha, let tag):
            PinLine(sha256: sha).accessibilityIdentifier(tag)
        case .number(let n):
            Text("\(n)").vettIDFont(.labelMedium).foregroundStyle(colors.onSurfaceVariant)
        }
    }
}

/// A line of text; the part of it that is [stress] in bold; a warning in the error colour.
private struct WayLine: View {
    @Environment(\.vettIDColors) private var colors
    let text: String
    var warning = false
    var mono = false
    var stress: String?

    var body: some View {
        var a = AttributedString(text)
        if let stress, let r = a.range(of: stress) { a[r].inlinePresentationIntent = .stronglyEmphasized }
        return Text(a)
            .vettIDFont(.bodyMedium)
            .monospaced(mono)
            .foregroundStyle(warning ? colors.error : colors.onSurface)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The fingerprint's first 16 digits; a tap shows all 64 (the member's own action: the gate stays as it is).
private struct PinLine: View {
    let sha256: String
    @State private var full = false

    var body: some View {
        Button { full.toggle() } label: {
            Text(WayRows.pinText(sha256, full: full)).vettIDFont(.bodyMedium).monospaced().frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .onChange(of: sha256) { _, _ in full = false }
    }
}
#endif
