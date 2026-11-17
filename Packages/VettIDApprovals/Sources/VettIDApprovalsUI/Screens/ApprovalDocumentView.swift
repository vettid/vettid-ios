#if os(iOS)
import SwiftUI
import VettIDApprovals
import VettIDData
import VettIDUI

/// An approval's document on its screen (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents", "What the app shows"): what
/// is asked, the service's description, its summary and the request, each under the app's own label and each value in a
/// block of its own that looks clearly different from the labels; or "This request can't be shown" when the document
/// failed its checks. When the end of the document comes on screen, the model is told (Approve waits for it).
struct ApprovalDocumentView: View {
    @Environment(\.vettIDColors) private var colors
    let step: DocumentStep
    let name: String?
    let seen: Bool
    let onRetry: @MainActor () -> Void
    let onSeenWhole: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            switch step {
            case .loading:
                HStack(spacing: Spacing.s) {
                    ProgressView()
                    Text(ApprovalsStrings.docLoading).vettIDFont(.bodyMedium)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("document_loading")
            case .failed(let kind):
                let text = ApprovalTexts.failure(kind, retryUntil: nil, limit: nil, now: Date())
                Text(text).vettIDFont(.bodyMedium).foregroundStyle(colors.error).announced(text, .assertive)
                    .accessibilityIdentifier("document_failure")
                NoticeAction(label: ApprovalsStrings.docRetry, identifier: "document_retry", action: onRetry)
            case .unshowable:
                NoticeCard(.warning, title: ApprovalsStrings.docCantShow, announce: .polite)
                    .accessibilityIdentifier("document_cant_show")
            case .shown(_, let p):
                shown(p)
                // The end of the document: once it has been on screen, the whole has (the screen opens at its top).
                Color.clear.frame(height: 1)
                    .onGeometryChange(for: Bool.self) { proxy in
                        guard let visible = proxy.bounds(of: .scrollView) else { return false }
                        return visible.intersects(proxy.frame(in: .local))
                    } action: { onScreen in
                        if onScreen { onSeenWhole() }
                    }
                    .accessibilityHidden(true)
                if !seen {
                    Text(ApprovalsStrings.docReadToEnd).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                        .accessibilityIdentifier("document_read_to_end")
                }
            }
        }
        .padding(.top, Spacing.l)
    }

    @ViewBuilder private func shown(_ p: DocumentPresentation) -> some View {
        Section(ApprovalsStrings.docAsked) {
            switch p.asked {
            case .known(let a): ValueBlock { Text(Self.title(a)).vettIDFont(.bodyLarge) }
            case .unknown(let action):
                ValueBlock { ShownTextView(text: ShownText(action)) }
                let who = AccountNames.isolateOrNull(name) ?? ApprovalsStrings.aConnection
                NoticeCard(.warning, title: ApprovalsStrings.docUnknownWarning(who))
                    .accessibilityIdentifier("document_unknown")
            }
        }
        if let context = p.context {
            Section(ApprovalsStrings.docDescription) {
                ValueBlock { ShownTextView(text: context) }
                Text(ApprovalsStrings.docDescriptionNote).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
            }
        }
        Section(ApprovalsStrings.docSummary) { ValueBlock { ShownTextView(text: p.summary) } }
        switch p.request {
        case .proposal(let f): Section(ApprovalsStrings.docRequest) { ProposalFormView(form: f) }
        case .extend(let f): Section(ApprovalsStrings.docRequest) { ExtendFormView(form: f) }
        case .raw(let lines): Section(ApprovalsStrings.docDetails) { RawDocumentView(lines: lines) }
        }
    }

    static func title(_ a: DocumentPresentation.KnownAction) -> String {
        switch a {
        case .proposalCreate: ApprovalsStrings.docTitleProposalCreate
        case .voteExtend: ApprovalsStrings.docTitleVoteExtend
        case .adminSetAdd: ApprovalsStrings.docTitleAdminSetAdd
        case .adminSetRemove: ApprovalsStrings.docTitleAdminSetRemove
        case .adminRepin: ApprovalsStrings.docTitleAdminRepin
        case .contractTemplateChange: ApprovalsStrings.docTitleContractTemplateChange
        case .assignmentPush: ApprovalsStrings.docTitleAssignmentPush
        }
    }
}

/// A part of the document under the app's own label: the label as a heading, the value blocks below it.
private struct Section<Content: View>: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(label).vettIDFont(.labelLarge).foregroundStyle(colors.onSurfaceVariant).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.top, Spacing.s)
    }
}

/// A value in a block of its own: framed and filled, so it cannot be taken for a label, and its own paragraph, so the
/// bidirectional order of its text reaches no other value or label (§10.4 "Text").
struct ValueBlock<Content: View>: View {
    @Environment(\.vettIDColors) private var colors
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.m)
            .background(colors.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(colors.outlineVariant, lineWidth: 1))
    }
}

/// A label inside a form's value: the label style, outside every value block.
private struct FieldLabel: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    var body: some View {
        Text(text).vettIDFont(.labelMedium).foregroundStyle(colors.onSurfaceVariant)
    }
}

/// A ``ShownText``: plain text (never markup, no links), wrapped and never cut, its markers in a style of their own so
/// that no string can imitate one; VoiceOver reads a marker as its code point.
struct ShownTextView: View {
    @Environment(\.vettIDColors) private var colors
    let text: ShownText

    var body: some View {
        Self.text(text, markerColor: colors.error)
            .vettIDFont(.bodyLarge)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.disabled)
            .accessibilityLabel(Self.spoken(text))
    }

    static func text(_ t: ShownText, markerColor: some ShapeStyle) -> Text {
        t.runs.reduce(Text(verbatim: "")) { acc, run in
            switch run {
            case .text(let s): acc + Text(verbatim: s)
            case .lineBreak: acc + Text(verbatim: "\n")
            case .marker(let v):
                acc + Text(verbatim: ShownText.marker(v)).font(.system(.body, design: .monospaced)).foregroundStyle(markerColor)
            }
        }
    }

    static func spoken(_ t: ShownText) -> String {
        t.runs.map { run -> String in
            switch run {
            case .text(let s): s
            case .lineBreak: "\n"
            case .marker(let v): " " + ApprovalsStrings.docMarkerSpoken("U+" + String(format: "%04X", v)) + " "
            }
        }.joined()
    }
}

/// A time of a form: in the member's time zone, then in UTC, each with its zone named.
private struct TimeValue: View {
    let seconds: Int64

    var body: some View {
        let t = DocumentTime.shown(seconds)
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: t.local).vettIDFont(.bodyLarge)
            Text(verbatim: t.utc).vettIDFont(.bodyMedium)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProposalFormView: View {
    @Environment(\.vettIDColors) private var colors
    let form: DocumentPresentation.ProposalForm

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            field(ApprovalsStrings.docFieldTitle) { ValueBlock { ShownTextView(text: form.title) } }
            field(ApprovalsStrings.docFieldMotion) {
                if let text = form.text {
                    ValueBlock { ShownTextView(text: text) }
                } else {
                    // "None" in the label style, outside any value block.
                    FieldLabel(text: ApprovalsStrings.docNone)
                }
            }
            field(ApprovalsStrings.docFieldChoices) {
                ForEach(Array(form.choices.enumerated()), id: \.offset) { _, c in ValueBlock { ShownTextView(text: c) } }
                HStack(spacing: Spacing.s) {
                    Text(ApprovalsStrings.docAbstain).vettIDFont(.bodyLarge)
                    FieldLabel(text: ApprovalsStrings.docAbstainAdded)
                }
                .accessibilityElement(children: .combine)
            }
            field(ApprovalsStrings.docFieldQuorum) {
                ValueBlock {
                    Text(ApprovalsStrings.docBallots(Int(clamping: form.quorumBallots))).vettIDFont(.bodyLarge)
                    if let text = form.quorumText { ShownTextView(text: text) }
                }
            }
            field(nil) {
                ValueBlock { Text(form.binding ? ApprovalsStrings.docBinding : ApprovalsStrings.docAdvisory).vettIDFont(.bodyLarge) }
            }
            field(ApprovalsStrings.docFieldRemovedMayVote) {
                ValueBlock { Text(form.removedMayVote ? ApprovalsStrings.docYes : ApprovalsStrings.docNo).vettIDFont(.bodyLarge) }
            }
            field(ApprovalsStrings.docFieldOpens) { ValueBlock { TimeValue(seconds: form.opensAt) } }
            field(ApprovalsStrings.docFieldCloses) { ValueBlock { TimeValue(seconds: form.closesAt) } }
            field(ApprovalsStrings.docFieldOutageRule) { ValueBlock { ShownTextView(text: form.outageRule) } }
        }
    }

    @ViewBuilder private func field(_ label: String?, @ViewBuilder _ value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let label { FieldLabel(text: label) }
            value()
        }
    }
}

private struct ExtendFormView: View {
    let form: DocumentPresentation.ExtendForm

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            field(ApprovalsStrings.docFieldVote) { ShownTextView(text: form.proposalID) }
            field(ApprovalsStrings.docFieldNewClose) { TimeValue(seconds: form.closesAt) }
            field(ApprovalsStrings.docFieldOutageFrom) { TimeValue(seconds: form.outageFrom) }
            field(ApprovalsStrings.docFieldOutageTo) { TimeValue(seconds: form.outageTo) }
            field(ApprovalsStrings.docFieldReportedBy) { ShownTextView(text: form.outageSource) }
        }
    }

    private func field<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        let shown = value()
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            FieldLabel(text: label)
            ValueBlock { shown }
        }
    }
}

/// The raw view (§10.4): the document as a tree, one member or element to a line, indented by depth, its base direction
/// left-to-right. Each key and each string is its own isolate (U+2068 … U+2069), with the quotation marks, punctuation and
/// numbers outside every isolate, so right-to-left text in one string cannot move a neighboring key, value, number or
/// bracket; a string keeps its quotation marks, so "10" and 10 never look the same.
struct RawDocumentView: View {
    @Environment(\.vettIDColors) private var colors
    let lines: [DocumentPresentation.RawLine]

    var body: some View {
        ValueBlock {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Self.text(line, markerColor: colors.error)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, CGFloat(min(line.depth, 16)) * 12)
                    .accessibilityLabel(Self.spoken(line))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    static let lrm = "\u{200E}"
    static let fsi = "\u{2068}"
    static let pdi = "\u{2069}"

    /// A string's text inside its own isolate (its markers stay inside: a marker is text, not a control).
    private static func isolated(_ t: ShownText, markerColor: some ShapeStyle) -> Text {
        Text(verbatim: fsi) + ShownTextView.text(t, markerColor: markerColor) + Text(verbatim: pdi)
    }

    static func text(_ line: DocumentPresentation.RawLine, markerColor: some ShapeStyle) -> Text {
        // A left-to-right mark first: the line's base direction is left-to-right whatever its isolates hold.
        var parts = [Text(verbatim: lrm)]
        if let key = line.key {
            parts += [Text(verbatim: "\""), isolated(key, markerColor: markerColor), Text(verbatim: "\": ")]
        }
        switch line.value {
        case .string(let s): parts += [Text(verbatim: "\""), isolated(s, markerColor: markerColor), Text(verbatim: "\"")]
        case .number(let n): parts.append(Text(verbatim: n))
        case .bool(let b): parts.append(Text(verbatim: b ? "true" : "false"))
        case .null: parts.append(Text(verbatim: "null"))
        case .open(let c): parts.append(Text(verbatim: c == .object ? "{" : "["))
        case .close(let c): parts.append(Text(verbatim: c == .object ? "}" : "]"))
        case .empty(let c): parts.append(Text(verbatim: c == .object ? "{}" : "[]"))
        }
        if line.comma { parts.append(Text(verbatim: ",")) }
        return parts.dropFirst().reduce(parts[0], +)
    }

    static func spoken(_ line: DocumentPresentation.RawLine) -> String {
        let key = line.key.map { ShownTextView.spoken($0) + ": " } ?? ""
        let value = switch line.value {
        case .string(let s): ApprovalsStrings.docTextSpoken(ShownTextView.spoken(s))
        case .number(let n): n
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        case .open(let c): c == .object ? "{" : "["
        case .close(let c): c == .object ? "}" : "]"
        case .empty(let c): c == .object ? "{}" : "[]"
        }
        return key + value
    }
}
#endif
