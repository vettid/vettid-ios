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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch approval {
            case .connection(.incoming(let r)): incoming(r)
            case .connection(.outgoing(let r)): outgoing(r)
            case .authentication(let x):
                FactLabel(ApprovalsStrings.from)
                FactValue(name ?? ApprovalsStrings.aConnection)
                // The challenger's claim (§10.4), in full whatever the purpose.
                if let c = x.context {
                    FactLabel(ApprovalsStrings.context)
                    FactValue(c).accessibilityIdentifier("auth_context")
                }
                expires(x.exp)
            case .critical(let c): CriticalFacts(use: c, name: name)
            case .device(let d):
                FactLabel(ApprovalsStrings.device)
                FactValue(Self.deviceLine(d))
                if let t = d.requestType {
                    FactLabel(ApprovalsStrings.request)
                    FactValue(t)
                }
                Text(ApprovalsStrings.deviceV1).vettIDFont(.bodyMedium)
            case .grant, .share: EmptyView()
            }
        }
    }

    /// The device's name and role, or "?".
    static func deviceLine(_ d: DeviceRequest) -> String {
        let parts = [d.deviceName, d.role].compactMap { $0 }
        return parts.isEmpty ? "?" : parts.joined(separator: " · ")
    }

    @ViewBuilder private func incoming(_ r: ConnectionRequest) -> some View {
        FactLabel(ApprovalsStrings.nameGiven)
        Text(r.name ?? ApprovalsStrings.nameNotShared).vettIDFont(.titleLarge, weight: .semibold).accessibilityIdentifier("request_name")
        if r.name != nil { FactNote(text: ApprovalsStrings.namesNote) }
        if let d = r.displayName {
            Text(ApprovalsStrings.displayName(AccountNames.isolate(d))).vettIDFont(.bodyMedium).padding(.top, Spacing.s)
            FactNote(text: ApprovalsStrings.selfAsserted)
        }
        if r.introducedBy != nil { Text(ApprovalsStrings.introduced).vettIDFont(.bodyMedium).padding(.top, Spacing.s) }
        sas(r.sas)
        FactNote(text: r.remote ? ApprovalsStrings.sasHintRemote : ApprovalsStrings.sasHint).padding(.top, Spacing.s)
        if r.state == .approved { waiting(r.name) }
        expires(r.exp)
    }

    @ViewBuilder private func outgoing(_ r: OutgoingRequest) -> some View {
        FactLabel(ApprovalsStrings.outgoingName)
        Text(r.name ?? ApprovalsStrings.nameNotShared).vettIDFont(.titleLarge, weight: .semibold)
        if let code = r.sas { sas(code) }
        if r.state == .approved { waiting(r.name) }
        expires(r.exp)
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

    var body: some View {
        FactLabel(ApprovalsStrings.from)
        FactValue(name ?? ApprovalsStrings.aConnection)
        FactLabel(ApprovalsStrings.criticalItem)
        FactValue("\(use.itemName) · \(use.fieldLabel)")
        if let k = use.kind {
            FactLabel(ApprovalsStrings.criticalKind)
            FactValue(ApprovalTexts.kind(k))
        }
        suitability
        FactLabel(ApprovalsStrings.criticalOperation)
        FactValue(ApprovalTexts.operation(use.operation))
        if let c = use.context {
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
        FactValue(state.connectionName ?? ApprovalsStrings.aConnection)
        if let r = request.reason {
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
                if e.kind == "item", e.available, e.name != nil, let theirs = e.label {
                    FactNote(text: ApprovalsStrings.grantTheirWords(theirs))
                }
                if e.kind == "item", e.available, let fields = e.labels, !fields.isEmpty {
                    FactNote(text: ApprovalsStrings.grantFields(fields.map(\.label).joined(separator: ", ")))
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
            ForEach(options) { item in Button(item.name) { actions.onAnswerGrant(i, item.id) } }
        } label: {
            Text(chosen.map { ApprovalsStrings.grantAnswerChosen($0) } ?? ApprovalsStrings.grantAnswer)
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
        name.map(AccountNames.isolate) ?? (decision.subjectAgentID != nil ? ApprovalsStrings.anAgent : ApprovalsStrings.aConnection)
    }

    var body: some View {
        if !decision.tags.isEmpty {
            FactLabel(ApprovalsStrings.shareTags)
            FactValue(decision.tags.joined(separator: ", "))
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
                    Text(i.name.isEmpty ? ApprovalsStrings.shareUnnamed : i.name).vettIDFont(.bodyLarge)
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
        }
        .buttonStyle(.plain)
        .frame(minHeight: Spacing.touchTarget)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("share_item_\(i.itemID)")
    }
}
#endif
