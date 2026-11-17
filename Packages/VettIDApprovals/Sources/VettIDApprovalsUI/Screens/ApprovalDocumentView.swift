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
struct ApprovalDocumentView: View, Equatable {
    @Environment(\.vettIDColors) private var colors
    let step: DocumentStep
    let name: String?
    let seen: Bool
    let onRetry: @MainActor () -> Void
    let onSeenWhole: @MainActor (String) -> Void

    /// What it shows: the screen's one-second countdown does not lay a large document out again (`.equatable()`).
    nonisolated static func == (a: Self, b: Self) -> Bool { a.step == b.step && a.name == b.name && a.seen == b.seen }

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
                DocumentRows(sha256: d.sha256, rows: rows(p), onSeenWhole: onSeenWhole)
                    // Another document is another view: its coverage starts again.
                    .id(d.sha256)
                if !seen {
                    Text(ApprovalsStrings.docReadToEnd).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                        .accessibilityIdentifier("document_read_to_end")
                }
            }
        }
        .padding(.top, Spacing.l)
    }

    /// The document as rows, each small: the parts under their labels, and every value of any length in pieces of at
    /// most ``ShownText/pieceCharacters`` characters (``ShownText/pieces(max:)``), so that the largest document is drawn
    /// a few rows at a time and every row is drawn whole.
    private func rows(_ p: DocumentPresentation) -> [AnyView] {
        var r: [AnyView] = [DocRows.heading(ApprovalsStrings.docAsked)]
        switch p.asked {
        case .known(let a): r.append(DocRows.block { Text(Self.title(a)).vettIDFont(.bodyLarge) })
        case .unknown(let action):
            r += DocRows.value(ShownText(action))
            let who = AccountNames.isolateOrNull(name) ?? ApprovalsStrings.aConnection
            r.append(AnyView(
                NoticeCard(.warning, title: ApprovalsStrings.docUnknownWarning(who)).padding(.top, Spacing.s)
                    .accessibilityIdentifier("document_unknown")
            ))
        }
        if let context = p.context {
            r.append(DocRows.heading(ApprovalsStrings.docDescription))
            r += DocRows.value(context)
            r.append(DocRows.note(ApprovalsStrings.docDescriptionNote))
        }
        r.append(DocRows.heading(ApprovalsStrings.docSummary))
        r += DocRows.value(p.summary)
        switch p.request {
        case .proposal(let f):
            r.append(DocRows.heading(ApprovalsStrings.docRequest))
            r += DocRows.proposal(f)
        case .extend(let f):
            r.append(DocRows.heading(ApprovalsStrings.docRequest))
            r += DocRows.extend(f)
        case .raw(let lines):
            r.append(DocRows.heading(ApprovalsStrings.docDetails))
            r += DocRows.raw(lines)
        }
        return r
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

/// The document's rows in a lazy stack: only the rows near the screen are drawn (the largest document, drawn whole,
/// takes more memory than an app is allowed). Each row follows which part of itself has been on screen
/// (``SeenCoverage``); once every row has been on screen whole, the model is told. A row never brought on screen (past a
/// jump to the end) is never seen, and a change of a row's height (another text size) starts that row again.
struct DocumentRows: View {
    let sha256: String
    let rows: [AnyView]
    let onSeenWhole: @MainActor (String) -> Void
    @State private var seen: Set<Int> = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                rows[i].modifier(RowSeen { rowSeen(i) })
            }
        }
    }

    private func rowSeen(_ i: Int) {
        guard !seen.contains(i) else { return }
        seen.insert(i)
        if seen.count == rows.count { onSeenWhole(sha256) }
    }
}

/// Says once that the whole of a row has been on screen in the enclosing scroll view.
struct RowSeen: ViewModifier {
    let onWhole: @MainActor () -> Void
    @State private var coverage = SeenCoverage()

    struct Seen: Equatable {
        var visible: ClosedRange<CGFloat>?
        var height: CGFloat
    }

    /// The part of the row on screen, in its own coordinates; none without a scroll view to measure against.
    static func seen(_ g: GeometryProxy) -> Seen {
        let h = g.size.height
        guard let b = g.bounds(of: .scrollView) else { return Seen(visible: nil, height: h) }
        let top = max(b.minY, 0), bottom = min(b.maxY, h)
        return Seen(visible: top <= bottom ? top...bottom : nil, height: h)
    }

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { g in
                Color.clear.onChange(of: Self.seen(g), initial: true) { _, now in
                    coverage.saw(now.visible, height: now.height)
                    if coverage.whole { onWhole() }
                }
            }
        )
    }
}

/// The rows of each part of a document.
@MainActor
enum DocRows {
    static func heading(_ label: String) -> AnyView {
        AnyView(DocHeading(label: label).padding(.top, Spacing.l).padding(.bottom, Spacing.s))
    }

    static func label(_ text: String) -> AnyView {
        AnyView(FieldLabel(text: text).padding(.top, Spacing.m).padding(.bottom, Spacing.xs))
    }

    static func note(_ text: String) -> AnyView { AnyView(DocNote(text: text).padding(.top, Spacing.s)) }

    /// A value in a block of its own, drawn as rows of bounded pieces that join into one block.
    static func value(_ t: ShownText, lineBreaks: Bool = false) -> [AnyView] {
        let pieces = t.pieces()
        return pieces.indices.map { i in
            AnyView(ValuePiece(first: i == 0, last: i == pieces.count - 1) { ShownTextView(text: pieces[i]) })
        }
    }

    /// A short value of the app's own words or a time, in a block of its own.
    static func block(@ViewBuilder _ content: @escaping @MainActor () -> some View) -> AnyView {
        AnyView(ValuePiece(first: true, last: true) { content() })
    }

    static func proposal(_ f: DocumentPresentation.ProposalForm) -> [AnyView] {
        var r: [AnyView] = [label(ApprovalsStrings.docFieldTitle)] + value(f.title)
        r.append(label(ApprovalsStrings.docFieldMotion))
        if let text = f.text { r += value(text) } else { r.append(AnyView(FieldLabel(text: ApprovalsStrings.docNone))) }
        r.append(label(ApprovalsStrings.docFieldChoices))
        for (i, c) in f.choices.enumerated() {
            r += value(c).enumerated().map { j, v in j == 0 && i > 0 ? AnyView(v.padding(.top, Spacing.xs)) : v }
        }
        r.append(AnyView(
            HStack(spacing: Spacing.s) {
                Text(ApprovalsStrings.docAbstain).vettIDFont(.bodyLarge)
                FieldLabel(text: ApprovalsStrings.docAbstainAdded)
            }
            .padding(.top, Spacing.xs)
            .accessibilityElement(children: .combine)
        ))
        r.append(label(ApprovalsStrings.docFieldQuorum))
        r.append(block { Text(ApprovalsStrings.docBallots(Int(clamping: f.quorumBallots))).vettIDFont(.bodyLarge) })
        if let text = f.quorumText { r += value(text).enumerated().map { j, v in j == 0 ? AnyView(v.padding(.top, Spacing.xs)) : v } }
        r.append(AnyView(block { Text(f.binding ? ApprovalsStrings.docBinding : ApprovalsStrings.docAdvisory).vettIDFont(.bodyLarge) }
            .padding(.top, Spacing.m)))
        r.append(label(ApprovalsStrings.docFieldRemovedMayVote))
        r.append(block { Text(f.removedMayVote ? ApprovalsStrings.docYes : ApprovalsStrings.docNo).vettIDFont(.bodyLarge) })
        r.append(label(ApprovalsStrings.docFieldOpens))
        r.append(block { TimeValue(seconds: f.opensAt) })
        r.append(label(ApprovalsStrings.docFieldCloses))
        r.append(block { TimeValue(seconds: f.closesAt) })
        r.append(label(ApprovalsStrings.docFieldOutageRule))
        r += value(f.outageRule)
        return r
    }

    static func extend(_ f: DocumentPresentation.ExtendForm) -> [AnyView] {
        [label(ApprovalsStrings.docFieldVote)] + value(f.proposalID)
            + [label(ApprovalsStrings.docFieldNewClose), block { TimeValue(seconds: f.closesAt) }]
            + [label(ApprovalsStrings.docFieldOutageFrom), block { TimeValue(seconds: f.outageFrom) }]
            + [label(ApprovalsStrings.docFieldOutageTo), block { TimeValue(seconds: f.outageTo) }]
            + [label(ApprovalsStrings.docFieldReportedBy)] + value(f.outageSource)
    }

    /// The raw view as rows of a few lines (``RawDocumentView/blocks(_:)``), joining into one block.
    static func raw(_ lines: [DocumentPresentation.RawLine]) -> [AnyView] {
        let blocks = RawDocumentView.blocks(lines[...])
        return blocks.indices.map { i in
            AnyView(ValuePiece(first: i == 0, last: i == blocks.count - 1) { RawBlockView(block: blocks[i]) })
        }
    }
}

/// A part's label as a heading.
private struct DocHeading: View {
    @Environment(\.vettIDColors) private var colors
    let label: String

    var body: some View {
        Text(label).vettIDFont(.labelLarge).foregroundStyle(colors.onSurfaceVariant).accessibilityAddTraits(.isHeader)
    }
}

/// The app's own line under a value.
private struct DocNote: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    var body: some View { Text(text).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant) }
}

/// One row of a value block: the block's fill, its rounded corners on its first and last row only, so that the rows of
/// one value join into one block.
struct ValuePiece<Content: View>: View {
    @Environment(\.vettIDColors) private var colors
    let first: Bool
    let last: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        let r: CGFloat = 8
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: first ? r : 0, bottomLeadingRadius: last ? r : 0, bottomTrailingRadius: last ? r : 0,
            topTrailingRadius: first ? r : 0
        )
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.m)
            .padding(.top, first ? Spacing.m : 0)
            .padding(.bottom, last ? Spacing.m : 0)
            .background(colors.surfaceContainerHigh, in: shape)
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
/// told from text by more than its color.
struct DocumentStyle {
    var marker: Color
    var markerFill: Color
    /// The fill behind a raw view's string, so that its content is told from the punctuation around it.
    var stringFill: Color

    init(marker: Color, markerFill: Color, stringFill: Color) {
        self.marker = marker
        self.markerFill = markerFill
        self.stringFill = stringFill
    }

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
                // Underlined too: told from text by more than its color.
                a.underlineStyle = .single
                out += a
            }
        }
        return out
    }
}

/// A ``ShownText``: plain text (never markup, no links), wrapped and never cut, its markers in a style of their own;
/// VoiceOver reads a marker as it is drawn, as punctuation.
struct ShownTextView: View {
    @Environment(\.vettIDColors) private var colors
    let text: ShownText

    var body: some View {
        // One piece of a value (``ShownText/pieces(max:)``): a bounded text.
        Text(DocumentStyle(colors).attributed(text))
            .vettIDFont(.bodyLarge)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.disabled)
            .accessibilityLabel(Spoken.text(Self.spoken(text)))
    }

    /// What VoiceOver reads: the document's own text as content, a marker as the app's words.
    static func spoken(_ t: ShownText) -> [Spoken] {
        t.runs.map { run -> Spoken in
            switch run {
            case .text(let s): .content(s)
            case .lineBreak: .content("\n")
            // The marker as it is drawn (⟨U+202E⟩), its punctuation spoken: no text can spell it (its brackets are markers).
            case .marker(let v): .symbol(ShownText.marker(v))
            }
        }
    }
}

/// A piece of what VoiceOver reads on this screen, and what a braille display shows. The separation does not rest on
/// pitch: the document's keys and strings are read between the quotation marks the screen draws, with their own `"` and
/// `\` escaped (so no content can close them), and those marks and the markers are spoken as punctuation; the
/// document's text has a pitch of its own as well, a cue only.
enum Spoken: Equatable {
    /// The app's words, at the usual pitch.
    case app(String)
    /// The app's quotation marks and markers, always spoken (and shown in braille) as punctuation.
    case symbol(String)
    /// The document's own text.
    case content(String)

    /// The pitch of the document's text. UIKit's scale is 0 to 2 with 1 the usual pitch, SwiftUI's -1 to 1 with 0; 0.5
    /// differs from the usual on either.
    static let contentPitch = 0.5

    static func plain(_ pieces: [Spoken]) -> String {
        pieces.map { p in
            switch p {
            case .app(let s), .symbol(let s), .content(let s): s
            }
        }.joined()
    }

    /// One attributed text: never a chain of concatenated texts, whose depth grows with the document (tens of thousands
    /// of pieces).
    static func attributed(_ pieces: [Spoken]) -> AttributedString {
        var out = AttributedString()
        for p in pieces {
            switch p {
            case .app(let s): out += AttributedString(s)
            case .symbol(let s):
                var a = AttributedString(s)
                a.accessibilitySpeechIncludesPunctuation = true
                out += a
            case .content(let s):
                var a = AttributedString(s)
                a.accessibilitySpeechAdjustedPitch = contentPitch
                out += a
            }
        }
        return out
    }

    static func text(_ pieces: [Spoken]) -> Text { Text(attributed(pieces)) }
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

/// One row of the raw view: a few lines, or the pieces of a long one, each a segment of a line.
struct RawBlock {
    struct Segment {
        var line: DocumentPresentation.RawLine
        /// Which of the line's pieces (``DocumentPieces/rawPieces(_:max:)``), and how many it has.
        var piece: Int
        var of: Int
    }

    var segments: [Segment]
}

/// A raw view's row, drawn as one text, left-to-right, monospaced; VoiceOver reads its lines (a piece after a line's
/// first is read as its text).
struct RawBlockView: View {
    @Environment(\.vettIDColors) private var colors
    let block: RawBlock

    var body: some View {
        let style = DocumentStyle(colors)
        let text = block.segments.enumerated().reduce(into: AttributedString()) { out, e in
            if e.offset > 0 { out += AttributedString("\n") }
            out += RawDocumentView.segment(e.element, style)
        }
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Spoken.text(Array(block.segments.map(RawDocumentView.spoken).joined(separator: [.app("\n")]))))
    }
}

/// The raw view (§10.4): the document as a tree, one member or element to a line, indented by depth, its base direction
/// left-to-right. Each key and each string is its own isolate (U+2068 … U+2069) on a fill of its own, with the quotation
/// marks, punctuation and numbers outside every isolate, so right-to-left text in one string cannot move a neighboring
/// key, value, number or bracket; a string keeps its quotation marks and shows its own `"` and `\` escaped, so "10" and 10
/// never look the same and no string can draw another member. The indent is spaces, so a wrapped line starts at the left
/// edge, never at a member's place. The lines go in rows (``blocks(_:)``) of at most ``chunk`` lines and
/// ``DocumentPieces/maxCharacters`` characters; a longer line is cut into pieces.
enum RawDocumentView {
    static let chunk = 20

    /// The style that only measures: the pieces' lengths do not depend on colors.
    static let measuring = DocumentStyle(marker: .clear, markerFill: .clear, stringFill: .clear)

    /// [lines] as rows.
    static func blocks(_ lines: ArraySlice<DocumentPresentation.RawLine>) -> [RawBlock] {
        var out: [RawBlock] = []
        var cur: [RawBlock.Segment] = []
        var count = 0
        for line in lines {
            let pieces = DocumentPieces.rawPieces(attributed(line, measuring))
            for (i, p) in pieces.enumerated() {
                let n = p.characters.count
                if !cur.isEmpty, cur.count >= chunk || count + n + 1 > DocumentPieces.maxCharacters {
                    out.append(RawBlock(segments: cur))
                    cur = []
                    count = 0
                }
                cur.append(RawBlock.Segment(line: line, piece: i, of: pieces.count))
                count += n + 1
            }
        }
        if !cur.isEmpty { out.append(RawBlock(segments: cur)) }
        return out
    }

    /// A segment's text in [style].
    static func segment(_ s: RawBlock.Segment, _ style: DocumentStyle) -> AttributedString {
        let full = attributed(s.line, style)
        guard s.of > 1 else { return full }
        let pieces = DocumentPieces.rawPieces(full)
        return pieces.indices.contains(s.piece) ? pieces[s.piece] : AttributedString()
    }

    /// What VoiceOver reads for a segment: a line's first piece reads the whole line, a later piece its own text.
    static func spoken(_ s: RawBlock.Segment) -> [Spoken] {
        guard s.piece > 0 else { return spoken(s.line) }
        let text = String(segment(s, measuring).characters).filter { ![lrm, fsi, pdi].contains(String($0)) }
        return [.content(text)]
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

    /// What VoiceOver reads for a line: its level (the document object is level 1, as §10.4 counts), then its key and
    /// value, a string said to be text; keys and strings are the document's content.
    static func spoken(_ line: DocumentPresentation.RawLine) -> [Spoken] {
        var out: [Spoken] = [.app(ApprovalsStrings.docLevelSpoken(line.depth + 1) + ", ")]
        // A key and a string between the quotation marks drawn around them; their content is already escaped.
        if let key = line.key { out += [.symbol("\"")] + ShownTextView.spoken(key) + [.symbol("\""), .app(": ")] }
        switch line.value {
        case .string(let s):
            // "<value>, text": the value spliced where the app's words put it (where a translation has no place for it,
            // the value first, as in English).
            let marker = "\u{FFFC}"
            let parts = ApprovalsStrings.docTextSpoken(marker).components(separatedBy: marker)
            let (before, after) = parts.count == 2 ? (parts[0], parts[1]) : ("", ApprovalsStrings.docTextSpoken(""))
            out.append(.app(before))
            out += [.symbol("\"")] + ShownTextView.spoken(s) + [.symbol("\"")]
            out.append(.app(after))
        case .number(let n): out.append(.content(n))
        case .bool(let b): out.append(.content(b ? "true" : "false"))
        case .null: out.append(.content("null"))
        case .open(let c): out.append(.app(c == .object ? "{" : "["))
        case .close(let c): out.append(.app(c == .object ? "}" : "]"))
        case .empty(let c): out.append(.app(c == .object ? "{}" : "[]"))
        }
        return out
    }
}
#endif
