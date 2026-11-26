#if os(iOS)
import SwiftUI
import VettIDApprovals
import VettIDData
import VettIDUI

/// A fact's label.
struct FactLabel: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View { Text(text).vettIDFont(.labelLarge).foregroundStyle(colors.onSurfaceVariant) }
}

/// A fact's value.
struct FactValue: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View { Text(text).vettIDFont(.bodyLarge).padding(.bottom, Spacing.m) }
}

/// The "From" fact's value: the connection's name, with the label "Service" beside it for a service (IOS-PLAN §4.13),
/// read together.
struct FromValue: View {
    let text: String
    let service: Bool

    var body: some View {
        ServiceNamed(service: service) { Text(text).vettIDFont(.bodyLarge) }
            .padding(.bottom, Spacing.m)
            .accessibilityIdentifier("approval_from")
    }
}

/// A small explanatory line.
struct FactNote: View {
    @Environment(\.vettIDColors) private var colors
    let text: String
    var color: ThemeColor?

    var body: some View { Text(text).vettIDFont(.bodySmall).foregroundStyle(color ?? colors.onSurfaceVariant) }
}

/// The facts of a request other than a grant or a share question: who, the safety code, the note, the critical item and
/// its payload, the device. Mirrors vettid-android `Facts`.
struct Facts: View {
    @Environment(\.vettIDColors) private var colors
    let approval: PendingApproval
    let name: String?
    /// The requesting connection is a service (VAULT-MESSAGING §6.4): "Service" beside its name.
    var service = false
    /// A renewal request (0.78.0 §6.8 step 3): its notice says what a deny does instead of the decline-only line.
    var renewal = false
    /// What an agent's held request shows (AA5), from the member's item list.
    var held: HeldShow?
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch approval {
            case .device(let d) where held != nil: HeldFacts(request: d, show: held ?? .other, now: now)
            case .connection(.incoming(let r)): incoming(r)
            case .connection(.outgoing(let r)): outgoing(r)
            case .authentication(let x):
                // A sign-in's match code comes first, directly under the title (0.79.0); its title already names the
                // connection, so the note follows the code (ANDROID-PLAN 0.1.100).
                if let code = x.matchCode {
                    MatchCodeBlock(code: code)
                } else {
                    FactLabel(ApprovalsStrings.from)
                    FromValue(text: AccountNames.isolateOrNull(name) ?? ApprovalsStrings.aConnectionInline, service: service)
                }
                // The challenger's claim (§10.4), in full whatever the purpose; a fixed line when a purpose comes without one.
                // With a document, it is shown with the document instead, as "The service's description" (0.89.0).
                if !x.hasDocument, let c = ApprovalTexts.contextNote(x) {
                    FactLabel(ApprovalsStrings.context)
                    FactValue(c).accessibilityIdentifier("auth_context")
                }
                // With a code, the sign-in's warning follows the note instead of the title (ANDROID-PLAN 0.1.100).
                if x.matchCode != nil {
                    Text(ApprovalsStrings.authSigninBody).vettIDFont(.bodyMedium).accessibilityIdentifier("auth_signin_body")
                }
                expires(x.exp)
            case .critical(let c): CriticalFacts(use: c, name: name, service: service)
            case .device(let d):
                FactLabel(ApprovalsStrings.device)
                FactValue(ApprovalTexts.deviceLine(d))
                if let t = d.requestType.flatMap(AuthContext.isolated) {
                    FactLabel(ApprovalsStrings.request)
                    FactValue(t)
                }
                if !renewal { Text(ApprovalsStrings.deviceV1).vettIDFont(.bodyMedium) }
            case .grant, .share: EmptyView()
            }
        }
    }

    @ViewBuilder private func incoming(_ r: ConnectionRequest) -> some View {
        FactLabel(ApprovalsStrings.nameGiven)
        Text(AccountNames.isolateOrNull(r.name) ?? ApprovalsStrings.nameNotShared)
            .vettIDFont(.titleLarge, weight: .semibold).accessibilityIdentifier("request_name")
        if AccountNames.cleaned(r.name) != nil { FactNote(text: ApprovalsStrings.namesNote) }
        if let d = AccountNames.isolateOrNull(r.displayName) {
            Text(ApprovalsStrings.displayName(d)).vettIDFont(.bodyMedium).padding(.top, Spacing.s)
            FactNote(text: ApprovalsStrings.selfAsserted)
        }
        if r.introducedBy != nil { Text(ApprovalsStrings.introduced).vettIDFont(.bodyMedium).padding(.top, Spacing.s) }
        sas(r.sas)
        FactNote(text: r.remote ? ApprovalsStrings.sasHintRemote : ApprovalsStrings.sasHint).padding(.top, Spacing.s)
        if r.state == .approved { waiting(r.name) }
        expires(r.exp)
    }

    /// An invitation this member accepted. From a service (its invitation said `peer_kind: "service"`, VAULT-MESSAGING
    /// §6.4): its name is "Name given by the service", and "This is a service, not a person." with its small print comes
    /// under the name, then the fingerprint of its `ik` when the vault sent one, and above the code (0.83.7 §6.4, §10.8). An
    /// incoming request has no `ik`, and a person's outgoing one shows none (chosen; not in the spec).
    @ViewBuilder private func outgoing(_ r: OutgoingRequest) -> some View {
        FactLabel(Self.outgoingNameLabel(r))
        Text(AccountNames.isolateOrNull(r.name) ?? ApprovalsStrings.nameNotShared).vettIDFont(.titleLarge, weight: .semibold)
        if r.isService {
            ServiceRequestLines().padding(.top, Spacing.s)
            if let fp = r.keyFingerprint {
                ServiceFingerprintLine(fingerprint: fp, labelColor: colors.onSurfaceVariant).padding(.top, Spacing.s)
            }
        }
        if let code = r.sas { sas(code) }
        if r.state == .approved { waiting(r.name) }
        expires(r.exp)
    }

    /// "Invitation from", or for a service "Name given by the service".
    static func outgoingNameLabel(_ r: OutgoingRequest) -> String {
        r.isService ? ServiceTexts.nameLabel : ApprovalsStrings.outgoingName
    }

    private func sas(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            FactLabel(ApprovalsStrings.safetyCode)
            CaptureProtected {
                SafetyCode(code)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.l)
                    .overlay(VettIDShape.card.stroke(colors.outline, lineWidth: 1))
            }
            .accessibilityIdentifier("sas")
        }
        .padding(.top, Spacing.l)
    }

    private func waiting(_ name: String?) -> some View {
        Text(ApprovalsStrings.waitingPeer(ApprovalTexts.them(name)))
            .vettIDFont(.bodyMedium)
            .padding(.top, Spacing.m)
            .accessibilityIdentifier("waiting_peer")
    }

    @ViewBuilder private func expires(_ exp: Date?) -> some View {
        if let exp { Text(ApprovalsStrings.expires(ApprovalTimes.full(exp))).vettIDFont(.bodySmall).padding(.top, Spacing.s) }
    }
}

/// A critical-item use (§10.13): the item and field, its kind and suitability, the operation, the note, and the data to
/// sign, shown only once SHA-256(payload) matches `payload_sha256`.
struct CriticalFacts: View {
    @Environment(\.vettIDColors) private var colors
    let use: CriticalUse
    let name: String?
    var service = false

    var body: some View {
        FactLabel(ApprovalsStrings.from)
        FromValue(text: AccountNames.isolateOrNull(name) ?? ApprovalsStrings.aConnectionInline, service: service)
        if let item = ApprovalTexts.criticalItem(use) {
            FactLabel(ApprovalsStrings.criticalItem)
            FactValue(item)
        }
        if let k = use.kind {
            FactLabel(ApprovalsStrings.criticalKind)
            FactValue(ApprovalTexts.kind(k))
        }
        suitability
        FactLabel(ApprovalsStrings.criticalOperation)
        FactValue(ApprovalTexts.operation(use.operation))
        if let c = use.context.flatMap(AuthContext.isolated) {
            FactLabel(ApprovalsStrings.context)
            FactValue(c)
        }
        payload
        if let exp = use.exp { Text(ApprovalsStrings.expires(ApprovalTimes.full(exp))).vettIDFont(.bodySmall).padding(.top, Spacing.s) }
    }

    /// 0.21.0 §10.13 Suitability, said before the password: nothing from a vault that gives no kind.
    @ViewBuilder private var suitability: some View {
        switch use.suitable {
        case false?:
            NoticeCard(.urgent, title: ApprovalsStrings.criticalUnsuitableTitle, message: ApprovalsStrings.criticalUnsuitableKind)
                .padding(.bottom, Spacing.m)
                .accessibilityIdentifier("critical_unsuitable")
        case true?:
            FactNote(text: ApprovalsStrings.criticalSuitableNote).padding(.bottom, Spacing.m).accessibilityIdentifier("critical_suitable")
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var payload: some View {
        if use.payloadVerified {
            FactLabel(ApprovalsStrings.payload)
            CaptureProtected {
                Text(use.payload)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colors.surfaceContainer, in: VettIDShape.card)
            }
            .accessibilityIdentifier("critical_payload")
        } else if use.payload.isEmpty {
            Text(ApprovalsStrings.payloadLoading).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
        } else {
            NoticeCard(.warning, title: ApprovalsStrings.payloadMismatchTitle, message: ApprovalsStrings.payloadMismatchBody)
                .accessibilityIdentifier("payload_mismatch")
        }
    }
}

/// A grant request (§10.12): each entry ticked or not (a named item if it exists, a category once the member picks one of
/// their items) and the uses and lifetime the grant gets. Mirrors vettid-android `GrantFacts`.
struct GrantFacts: View {
    @Environment(\.vettIDColors) private var colors
    let request: GrantRequest
    let state: ApprovalDetailState
    let actions: DecisionActions

    var body: some View {
        FactLabel(ApprovalsStrings.from)
        FactValue(AccountNames.isolateOrNull(state.connectionName) ?? ApprovalsStrings.aConnectionInline)
        if let r = request.reason.flatMap(AuthContext.isolated) {
            FactLabel(ApprovalsStrings.reason)
            FactValue(r)
        }
        FactLabel(ApprovalsStrings.itemsAsked)
        ForEach(Array(request.entries.enumerated()), id: \.offset) { i, e in entry(i, e) }
        FactLabel(ApprovalsStrings.grantUsesLabel).padding(.top, Spacing.s)
        chips(ApprovalTexts.usesOptions(requested: request.uses), selected: state.grantUses, label: {
            ApprovalTexts.usesLabel($0, requested: request.uses)
        }, action: actions.onGrantUses)
        FactLabel(ApprovalsStrings.grantExpiryLabel)
        let requested = request.expiresIn.map { Int($0) }
        chips(ApprovalTexts.expiryOptions(requested: requested), selected: state.grantExpiresIn, label: {
            ApprovalTexts.expiryLabel($0, requested: requested)
        }, action: actions.onGrantExpiresIn)
        FactNote(text: ApprovalsStrings.grantNote).padding(.top, Spacing.s)
    }

    private func chips(
        _ options: [Int?], selected: Int?, label: @escaping (Int?) -> String, action: @escaping @MainActor (Int?) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                    VettIDFilterChip(label(o), selected: selected == o) { action(o) }
                }
            }
        }
        .padding(.bottom, Spacing.m)
    }

    private func entry(_ i: Int, _ e: GrantEntry) -> some View {
        let answer = state.grantAnswers[i].flatMap { id in state.items.first { $0.id == id } }
        let grantable = (e.kind == "item" && e.available) || answer != nil
        let on = state.grantIndexes.contains(i)
        return HStack(alignment: .top, spacing: Spacing.m) {
            Button { actions.onToggleGrant(i) } label: {
                (on ? VettIDSymbol.checkBox : VettIDSymbol.checkBoxOutline).image
                    .foregroundStyle(grantable ? colors.primary : colors.onSurfaceVariant)
                    .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
            }
            .buttonStyle(.plain)
            .disabled(!grantable)
            .accessibilityLabel(ApprovalTexts.grantEntry(e))
            .accessibilityAddTraits(on ? .isSelected : [])
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(ApprovalTexts.grantEntry(e)).vettIDFont(.bodyLarge)
                if e.kind == "item", e.available, e.name != nil, let theirs = AccountNames.isolateOrNull(e.label) {
                    FactNote(text: ApprovalsStrings.grantTheirWords(theirs))
                }
                if e.kind == "item", e.available, let fields = e.labels?.compactMap({ AccountNames.isolateOrNull($0.label) }),
                   !fields.isEmpty {
                    FactNote(text: ApprovalsStrings.grantFields(fields.joined(separator: ", ")))
                        .accessibilityIdentifier("grant_fields_\(i)")
                }
                if e.kind == "category" { picker(i, category: e.ref, chosen: answer?.name) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: Spacing.touchTarget)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("grant_entry_\(i)")
    }

    /// The asked category first, then the member's other items (§10.12: the member picks the item).
    private func picker(_ i: Int, category: String, chosen: String?) -> some View {
        let options = state.answerable.sorted { ($0.category == category ? 0 : 1) < ($1.category == category ? 0 : 1) }
        return Menu {
            if options.isEmpty { Text(ApprovalsStrings.grantAnswerNone) }
            ForEach(options) { item in
                Button(AccountNames.isolateOrNull(item.name) ?? ApprovalsStrings.shareUnnamed) { actions.onAnswerGrant(i, item.id) }
            }
        } label: {
            Text(chosen.map { ApprovalsStrings.grantAnswerChosen(AccountNames.isolate($0)) } ?? ApprovalsStrings.grantAnswer)
                .vettIDFont(.labelLarge, weight: .semibold)
                .foregroundStyle(colors.primary)
                .frame(minHeight: Spacing.touchTarget)
        }
        .accessibilityIdentifier("grant_answer_\(i)")
    }
}

/// A share rule's items waiting for the member (§10.12 `share.pending`): ticked items are shared, unticked ones declined
/// (and not asked again until they gain the rule again); the rule's tags say why they were asked. Mirrors vettid-android
/// `ShareFacts`.
struct ShareFacts: View {
    @Environment(\.vettIDColors) private var colors
    let decision: ShareDecision
    let excluded: Set<String>
    let name: String?
    let onToggle: @MainActor (String) -> Void

    private var who: String {
        AccountNames.isolateOrNull(name)
            ?? (decision.subjectAgentID != nil ? ApprovalsStrings.anAgentInline : ApprovalsStrings.aConnectionInline)
    }

    var body: some View {
        let tags = decision.tags.compactMap { AccountNames.isolateOrNull($0) }
        if !tags.isEmpty {
            FactLabel(ApprovalsStrings.shareTags)
            FactValue(tags.joined(separator: ", "))
        }
        if let r = decision.reason {
            Text(r == "rule" ? ApprovalsStrings.shareReasonRule : ApprovalsStrings.shareReasonTagged)
                .vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant).padding(.bottom, Spacing.s)
        }
        FactLabel(ApprovalsStrings.shareItems)
        let names = RuleNames.of(decision.rules)
        ForEach(decision.items, id: \.itemID) { item($0, names) }
        FactNote(text: ApprovalsStrings.shareNote).padding(.top, Spacing.s)
        if decision.items.contains(where: { !$0.alsoIn.isEmpty || $0.askRuleID != nil || $0.shared }) {
            FactNote(text: ApprovalsStrings.shareOneAnswer(who)).accessibilityIdentifier("share_one_answer")
        }
    }

    private func item(_ i: ShareItem, _ names: [String: RuleNames.Name]) -> some View {
        let on = !excluded.contains(i.itemID)
        return Button { onToggle(i.itemID) } label: {
            HStack(alignment: .top, spacing: Spacing.m) {
                (on ? VettIDSymbol.checkBox : VettIDSymbol.checkBoxOutline).image.foregroundStyle(colors.primary)
                    .frame(width: 24, height: Spacing.touchTarget)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(AccountNames.isolateOrNull(i.name) ?? ApprovalsStrings.shareUnnamed).vettIDFont(.bodyLarge)
                    if i.sensitivity == "critical" { FactNote(text: ApprovalsStrings.shareUsable) }
                    ForEach(Array(ShareExplanations.of(i, decision).enumerated()), id: \.offset) { _, line in
                        FactNote(
                            text: ApprovalTexts.shareLine(line, in: decision, names: names, who: who),
                            color: line == .alreadyShared ? colors.error : nil
                        )
                        .accessibilityIdentifier("share_item_note_\(i.itemID)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: Spacing.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("share_item_\(i.itemID)")
    }
}

/// A service a desktop's block or removal names (ANDROID-PLAN 0.1.145): its name (with any "(connected <date>)") and the label
/// "Service" after it, read together.
struct DesktopServiceLine: View {
    let target: DesktopTargets.Shown

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text(ApprovalTexts.desktopTarget(target)).vettIDFont(.bodyMedium)
            ServiceLabel()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("desktop_service")
    }
}

/// An agent's held request on its screen (AA5): how long it waits, the kind of device (so that an agent calling itself "Work
/// desktop" still shows "Agent"), and what it asks: for `item.use` the data the result is computed over, in a box with its label
/// and length so that the agent's text cannot pass for one of the app's own lines; for a reveal the fields and, always, that
/// the agent's app may keep the value in its history. Mirrors vettid-android `HeldFacts`.
struct HeldFacts: View {
    @Environment(\.vettIDColors) private var colors
    let request: DeviceRequest
    let show: HeldShow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A service named in the title carries the label beside its name (IOS-PLAN §4.13), first under the title, before
            // the "Desktop" kind word, so that it cannot be read as the desktop's (ANDROID-PLAN 0.1.145).
            if case .desktopConnection(_, let target, _) = show, target.service {
                DesktopServiceLine(target: target).padding(.bottom, Spacing.m)
            }
            if let waiting = ApprovalTexts.waitingText(request.exp, now: now) {
                Text(waiting).vettIDFont(.bodyMedium).padding(.bottom, Spacing.m).accessibilityIdentifier("device_waiting")
            }
            Text(ApprovalTexts.kindWord(request)).vettIDFont(.titleMedium).accessibilityIdentifier("device_kind")
            switch show {
            case .use(_, _, let data, let bytes): useData(data, bytes: bytes).padding(.top, Spacing.m)
            case .get(_, let fields): reveal(fields).padding(.top, Spacing.m)
            case .desktopConnection(_, _, let note?): desktopNote(note).padding(.top, Spacing.m)
            default: EmptyView()
            }
        }
    }

    /// A block's note: the desktop's own words, labeled with its name (ANDROID-PLAN 0.1.146) and in their own box apart from the
    /// body (0.1.145), so that they cannot pass for the app's; cleaned with their lines kept, each line isolated.
    private func desktopNote(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(ApprovalsStrings.desktopNoteFrom(ApprovalTexts.deviceSentenceStart(.device(request))))
                .vettIDFont(.labelLarge).accessibilityIdentifier("desktop_note_label")
            Text(AccountNames.isolateLines(note))
                .vettIDFont(.bodyLarge)
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(colors.outline))
                .accessibilityIdentifier("desktop_note")
        }
        // One element: the label and the note are read together, as the desktop's.
        .accessibilityElement(children: .combine)
    }

    private func useData(_ data: DataView, bytes: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(ApprovalsStrings.heldUseData).vettIDFont(.labelMedium)
            Text(ApprovalsStrings.heldUseBytes(bytes)).vettIDFont(.labelMedium).accessibilityIdentifier("use_data_bytes")
            switch data {
            case .text(let t): Text(t).vettIDFont(.bodyLarge).accessibilityIdentifier("use_data_text")
            case .hex(let h):
                Text(ApprovalsStrings.heldUseDataHex).vettIDFont(.bodySmall)
                Text(h).vettIDFont(.bodyMedium).monospaced().accessibilityIdentifier("use_data_hex")
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(colors.outline))
        // One element: the label, the length and the agent's text are read together, as the agent's data.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("use_data_box")
    }

    private func reveal(_ fields: [String]?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(fields.map { ApprovalsStrings.heldGetFields($0.map { AccountNames.isolate($0) }.joined(separator: ", ")) }
                ?? ApprovalsStrings.heldGetAll)
                .vettIDFont(.bodyLarge).accessibilityIdentifier("get_fields")
            // Always, with or without the `history` flag (since 0.42.0 every item.get is a reveal).
            Text(ApprovalsStrings.heldGetHistory).vettIDFont(.bodyLarge).accessibilityIdentifier("get_history")
        }
    }
}
#endif
