#if os(iOS)
import SwiftUI
import VettIDApprovals
import VettIDData
import VettIDUI

/// An approval's document on its screen (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents", "What the app shows"): what
/// is asked, the service's description, its summary and the request, each under the app's own label and each value in a
/// block of its own that looks clearly different from the labels; or "This request can't be shown" when the document
/// failed its checks. Once the whole of the document has been on screen, from its top down without a gap, the model is
/// told (Approve waits for it).
struct ApprovalDocumentView: View {
    @Environment(\.vettIDColors) private var colors
    let step: DocumentStep
    let name: String?
    let seen: Bool
    let onRetry: @MainActor () -> Void
    let onSeenWhole: @MainActor (String) -> Void

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
            case .shown(let d, let p):
                DocumentCoverage(sha256: d.sha256, onSeenWhole: onSeenWhole) {
                    VStack(alignment: .leading, spacing: Spacing.m) { shown(p) }
                }
                // Another document is another view: its coverage starts again from its top.
                .id(d.sha256)
                if !seen {
                    Text(ApprovalsStrings.docReadToEnd).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                        .accessibilityIdentifier("document_read_to_end")
                }
            }
        }
        .padding(.top, Spacing.l)
    }

    @ViewBuilder private func shown(_ p: DocumentPresentation) -> some View {
        DocSection(ApprovalsStrings.docAsked) {
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
            DocSection(ApprovalsStrings.docDescription) {
                ValueBlock { ShownTextView(text: context) }
                Text(ApprovalsStrings.docDescriptionNote).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
            }
        }
        DocSection(ApprovalsStrings.docSummary) { ValueBlock { ShownTextView(text: p.summary) } }
        switch p.request {
        case .proposal(let f): DocSection(ApprovalsStrings.docRequest) { ProposalFormView(form: f) }
        case .extend(let f): DocSection(ApprovalsStrings.docRequest) { ExtendFormView(form: f) }
        case .raw(let lines): DocSection(ApprovalsStrings.docDetails) { RawDocumentView(lines: lines) }
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

/// Follows which part of [content] is on screen in the enclosing scroll view (``SeenCoverage``) and says once that the
/// whole of it has been, from its top down without a gap: a jump past its middle does not count, and a change of its
/// height (another text size) starts again. When there is no scroll view to measure against, nothing is ever seen.
struct DocumentCoverage<Content: View>: View {
    let sha256: String
    let onSeenWhole: @MainActor (String) -> Void
    @ViewBuilder let content: () -> Content
    @State private var coverage = SeenCoverage()

    struct Seen: Equatable {
        var visible: ClosedRange<CGFloat>?
        var height: CGFloat
    }

    static func seen(_ g: GeometryProxy) -> Seen {
        let h = g.size.height
        guard let b = g.bounds(of: .scrollView) else { return Seen(visible: nil, height: h) }
        let top = max(b.minY, 0), bottom = min(b.maxY, h)
        return Seen(visible: top <= bottom ? top...bottom : nil, height: h)
    }

    var body: some View {
        content().background(
            GeometryReader { g in
                Color.clear.onChange(of: Self.seen(g), initial: true) { _, now in
                    let before = coverage.whole
                    coverage.saw(now.visible, height: now.height)
                    if coverage.whole, !before { onSeenWhole(sha256) }
                }
            }
        )
    }
}

/// A part of the document under the app's own label: the label as a heading, the value blocks below it.
private struct DocSection<Content: View>: View {
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

/// How the document's texts are drawn: a marker in a monospaced, boxed and underlined style of its own, so that it is
/// told from text by more than its colour.
struct DocumentStyle {
    var marker: Color
    var markerFill: Color
    /// The fill behind a raw view's string, so that its content is told from the punctuation around it.
    var stringFill: Color

    init(_ colors: VettIDColors) {
        marker = colors.error.color
        markerFill = colors.error.color.opacity(0.14)
        stringFill = colors.secondaryContainer.color
    }

    /// [t] as one attributed run list: text as itself, kept line breaks, markers in their style. Adjacent runs of one
    /// style coalesce, so a document of 65,536 markers stays one text.
    func attributed(_ t: ShownText, fill: Color? = nil) -> AttributedString {
        var out = AttributedString()
        for run in t.runs {
            switch run {
            case .text(let s):
                var a = AttributedString(s)
                if let fill { a.backgroundColor = fill }
                out += a
            case .lineBreak: out += AttributedString("\n")
            case .marker(let v):
                var a = AttributedString(ShownText.marker(v))
                a.font = .system(.body, design: .monospaced)
                a.foregroundColor = marker
                a.backgroundColor = markerFill
                // Underlined too: told from text by more than its colour.
                a.underlineStyle = .single
                out += a
            }
        }
        return out
    }
}

/// A ``ShownText``: plain text (never markup, no links), wrapped and never cut, its markers in a style of their own;
/// VoiceOver reads a marker as its code point.
struct ShownTextView: View {
    @Environment(\.vettIDColors) private var colors
    let text: ShownText

    var body: some View {
        Text(DocumentStyle(colors).attributed(text))
            .vettIDFont(.bodyLarge)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.disabled)
            .accessibilityLabel(Self.spoken(text))
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
                // The app's own count, then the service's text in a block of its own.
                ValueBlock { Text(ApprovalsStrings.docBallots(Int(clamping: form.quorumBallots))).vettIDFont(.bodyLarge) }
                if let text = form.quorumText { ValueBlock { ShownTextView(text: text) } }
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
/// left-to-right. Each key and each string is its own isolate (U+2068 … U+2069) on a fill of its own, with the quotation
/// marks, punctuation and numbers outside every isolate, so right-to-left text in one string cannot move a neighboring
/// key, value, number or bracket; a string keeps its quotation marks and shows its own `"` and `\` escaped, so "10" and 10
/// never look the same and no string can draw another member. The indent is spaces, so a wrapped line starts at the left
/// edge, never at a member's place. The lines are drawn in blocks of ``chunk``, each one text, so that the largest
/// document stays a few hundred views.
struct RawDocumentView: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let lines: [DocumentPresentation.RawLine]

    static let chunk = 40
    static let voiceOverLines = 2000

    var body: some View {
        let style = DocumentStyle(colors)
        // With VoiceOver, one element to a line: moving from one to the next brings each on screen in turn, so the
        // coverage has no gap and each line is read with its level. Not past ``voiceOverLines`` lines, which would be as
        // many views: there the blocks stay, and scrolling over them completes the coverage.
        let chunk = voiceOver && lines.count <= Self.voiceOverLines ? 1 : Self.chunk
        ValueBlock {
            ForEach(Array(stride(from: 0, to: lines.count, by: chunk)), id: \.self) { start in
                let part = lines[start..<min(start + chunk, lines.count)]
                Text(part.enumerated().reduce(into: AttributedString()) { out, e in
                    if e.offset > 0 { out += AttributedString("\n") }
                    out += Self.attributed(e.element, style)
                })
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(part.map(Self.spoken).joined(separator: "\n"))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    static let lrm = "\u{200E}"
    static let fsi = "\u{2068}"
    static let pdi = "\u{2069}"

    /// A key's or string's text inside its own isolate, on the string fill.
    private static func isolated(_ t: ShownText, _ style: DocumentStyle) -> AttributedString {
        AttributedString(fsi) + style.attributed(t, fill: style.stringFill) + AttributedString(pdi)
    }

    static func attributed(_ line: DocumentPresentation.RawLine, _ style: DocumentStyle) -> AttributedString {
        // A left-to-right mark first: the line's base direction is left-to-right whatever its isolates hold.
        var t = AttributedString(lrm + String(repeating: "  ", count: line.depth))
        if let key = line.key { t += AttributedString("\"") + isolated(key, style) + AttributedString("\": ") }
        switch line.value {
        case .string(let s): t += AttributedString("\"") + isolated(s, style) + AttributedString("\"")
        case .number(let n): t += AttributedString(n)
        case .bool(let b): t += AttributedString(b ? "true" : "false")
        case .null: t += AttributedString("null")
        case .open(let c): t += AttributedString(c == .object ? "{" : "[")
        case .close(let c): t += AttributedString(c == .object ? "}" : "]")
        case .empty(let c): t += AttributedString(c == .object ? "{}" : "[]")
        }
        if line.comma { t += AttributedString(",") }
        return t
    }

    /// What VoiceOver reads for a line: its level, then its key and value, a string said to be text.
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
        return ApprovalsStrings.docLevelSpoken(line.depth) + ", " + key + value
    }
}
#endif
