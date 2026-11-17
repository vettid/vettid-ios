#if os(iOS)
import SwiftUI
import VettIDApprovals
import VettIDData
import VettIDUI

/// An approval's document on its screen (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents", "What the app shows"): what
/// is asked, the service's description, its summary and the request, each under the app's own label and each value in a
/// block of its own that looks clearly different from the labels; or "This request can't be shown" when the document
/// failed its checks. Once every row of the document has been on screen whole (``DocumentRows``), the model is told
/// (Approve waits for it).
struct ApprovalDocumentView: View, Equatable {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let step: DocumentStep
    /// Counts the documents shown: the same document shown again is followed again from nothing seen.
    var generation = 0
    let name: String?
    let seen: Bool
    let onRetry: @MainActor () -> Void
    let onSeenWhole: @MainActor (String) -> Void

    /// What it shows: the screen's one-second countdown does not lay a large document out again (`.equatable()`).
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.step == b.step && a.generation == b.generation && a.name == b.name && a.seen == b.seen
    }

    /// Characters to a piece: with VoiceOver, small enough that a piece fits on the screen at the largest text size, so
    /// moving from one element to the next brings every part on screen.
    static let voiceOverPieceCharacters = 60

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
                    // Another document, or the same shown again, is another view: its coverage starts again.
                    .id("\(d.sha256) \(generation)")
                if !seen {
                    Text(ApprovalsStrings.docReadToEnd).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                        .accessibilityIdentifier("document_read_to_end")
                }
            }
        }
        .padding(.top, Spacing.l)
    }

    /// The document as rows, each small: the parts under their labels, and every value of any length in pieces
    /// (``DocPiece``), so that the largest document is drawn a few rows at a time and every row is drawn whole.
    private func rows(_ p: DocumentPresentation) -> [AnyView] {
        let d = DocRows(max: voiceOver ? Self.voiceOverPieceCharacters : ShownText.pieceCharacters)
        var r: [AnyView] = [DocRows.heading(ApprovalsStrings.docAsked)]
        switch p.asked {
        case .known(let a): r.append(DocRows.block { Text(Self.title(a)).vettIDFont(.bodyLarge) })
        case .unknown(let action):
            r += d.value(ShownText(action))
            let who = AccountNames.isolateOrNull(name) ?? ApprovalsStrings.aConnection
            r.append(AnyView(
                NoticeCard(.warning, title: ApprovalsStrings.docUnknownWarning(who)).padding(.top, Spacing.s)
                    .accessibilityIdentifier("document_unknown")
            ))
        }
        if let context = p.context {
            r.append(DocRows.heading(ApprovalsStrings.docDescription))
            r += d.value(context)
            r.append(DocRows.note(ApprovalsStrings.docDescriptionNote))
        }
        r.append(DocRows.heading(ApprovalsStrings.docSummary))
        r += d.value(p.summary)
        switch p.request {
        case .proposal(let f):
            r.append(DocRows.heading(ApprovalsStrings.docRequest))
            r += d.proposal(f)
        case .extend(let f):
            r.append(DocRows.heading(ApprovalsStrings.docRequest))
            r += d.extend(f)
        case .raw(let lines):
            r.append(DocRows.heading(ApprovalsStrings.docDetails))
            r += d.raw(lines, perRow: voiceOver ? 1 : 20)
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
/// takes more memory than an app may hold). Each row follows which part of itself has been on screen
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

/// The rows of each part of a document, built from ``DocPiece``s of at most [max] characters.
@MainActor
struct DocRows {
    let max: Int

    static func heading(_ label: String) -> AnyView {
        AnyView(DocHeading(label: label).padding(.top, Spacing.l).padding(.bottom, Spacing.s))
    }

    static func label(_ text: String) -> AnyView {
        AnyView(FieldLabel(text: text).padding(.top, Spacing.m).padding(.bottom, Spacing.xs))
    }

    static func note(_ text: String) -> AnyView { AnyView(DocNote(text: text).padding(.top, Spacing.s)) }

    /// A value in a block of its own, as rows of pieces that join into one block.
    func value(_ t: ShownText) -> [AnyView] {
        let pieces = DocPiece.value(t, max: max)
        return pieces.indices.map { i in
            AnyView(ValuePiece(first: i == 0, last: i == pieces.count - 1) { DocPieceView(pieces: [pieces[i]], raw: false) })
        }
    }

    /// A short value of the app's own words or a time, in a block of its own.
    static func block(@ViewBuilder _ content: @escaping @MainActor () -> some View) -> AnyView {
        AnyView(ValuePiece(first: true, last: true) { content() })
    }

    func proposal(_ f: DocumentPresentation.ProposalForm) -> [AnyView] {
        var r: [AnyView] = [Self.label(ApprovalsStrings.docFieldTitle)] + value(f.title)
        r.append(Self.label(ApprovalsStrings.docFieldMotion))
        if let text = f.text { r += value(text) } else { r.append(AnyView(FieldLabel(text: ApprovalsStrings.docNone))) }
        r.append(Self.label(ApprovalsStrings.docFieldChoices))
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
        r.append(Self.label(ApprovalsStrings.docFieldQuorum))
        r.append(Self.block { Text(ApprovalsStrings.docBallots(Int(clamping: f.quorumBallots))).vettIDFont(.bodyLarge) })
        if let text = f.quorumText {
            r += value(text).enumerated().map { j, v in j == 0 ? AnyView(v.padding(.top, Spacing.xs)) : v }
        }
        r.append(AnyView(
            Self.block { Text(f.binding ? ApprovalsStrings.docBinding : ApprovalsStrings.docAdvisory).vettIDFont(.bodyLarge) }
                .padding(.top, Spacing.m)
        ))
        r.append(Self.label(ApprovalsStrings.docFieldRemovedMayVote))
        r.append(Self.block { Text(f.removedMayVote ? ApprovalsStrings.docYes : ApprovalsStrings.docNo).vettIDFont(.bodyLarge) })
        r.append(Self.label(ApprovalsStrings.docFieldOpens))
        r.append(Self.block { TimeValue(seconds: f.opensAt) })
        r.append(Self.label(ApprovalsStrings.docFieldCloses))
        r.append(Self.block { TimeValue(seconds: f.closesAt) })
        r.append(Self.label(ApprovalsStrings.docFieldOutageRule))
        r += value(f.outageRule)
        return r
    }

    func extend(_ f: DocumentPresentation.ExtendForm) -> [AnyView] {
        [Self.label(ApprovalsStrings.docFieldVote)] + value(f.proposalID)
            + [Self.label(ApprovalsStrings.docFieldNewClose), Self.block { TimeValue(seconds: f.closesAt) }]
            + [Self.label(ApprovalsStrings.docFieldOutageFrom), Self.block { TimeValue(seconds: f.outageFrom) }]
            + [Self.label(ApprovalsStrings.docFieldOutageTo), Self.block { TimeValue(seconds: f.outageTo) }]
            + [Self.label(ApprovalsStrings.docFieldReportedBy)] + value(f.outageSource)
    }

    /// The raw view as rows of a few pieces each (one with VoiceOver), joining into one block.
    func raw(_ lines: [DocumentPresentation.RawLine], perRow: Int) -> [AnyView] {
        var rows: [[DocPiece]] = []
        var cur: [DocPiece] = []
        var count = 0
        for p in lines.flatMap({ DocPiece.raw($0, max: max) }) {
            if !cur.isEmpty, cur.count >= perRow || count + p.length + 1 > max {
                rows.append(cur)
                cur = []
                count = 0
            }
            cur.append(p)
            count += p.length + 1
        }
        if !cur.isEmpty { rows.append(cur) }
        return rows.indices.map { i in
            AnyView(
                ValuePiece(first: i == 0, last: i == rows.count - 1) { DocPieceView(pieces: rows[i], raw: true) }
                    .environment(\.layoutDirection, .leftToRight)
            )
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

/// One row of a value block: the block's fill and outline, rounded at its first and last row only, so that the rows of
/// one value join into one block.
struct ValuePiece<Content: View>: View {
    @Environment(\.vettIDColors) private var colors
    let first: Bool
    let last: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.m)
            .padding(.top, first ? Spacing.m : 0)
            .padding(.bottom, last ? Spacing.m : 0)
            .background(colors.surfaceContainerHigh, in: PieceShape(first: first, last: last, outline: false))
            .overlay(PieceShape(first: first, last: last, outline: true).stroke(colors.outlineVariant, lineWidth: 1))
    }
}

/// A row's part of its block: filled, it is the block's slice; outlined, its sides, and its top and bottom only where the
/// block begins and ends.
struct PieceShape: Shape {
    let first: Bool
    let last: Bool
    let outline: Bool
    var radius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let top = first ? radius : 0, bottom = last ? radius : 0
        var p = Path()
        if !outline {
            return Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
                topLeading: top, bottomLeading: bottom, bottomTrailing: bottom, topTrailing: top
            ))
        }
        // Down the leading side, across the bottom where the block ends, up the trailing side, across the top where it
        // begins.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + top))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        if last {
            p.addArc(center: CGPoint(x: rect.minX + bottom, y: rect.maxY - bottom), radius: bottom, startAngle: .degrees(180),
                     endAngle: .degrees(90), clockwise: true)
            p.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
            p.addArc(center: CGPoint(x: rect.maxX - bottom, y: rect.maxY - bottom), radius: bottom, startAngle: .degrees(90),
                     endAngle: .degrees(0), clockwise: true)
        } else {
            p.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))
        if first {
            p.addArc(center: CGPoint(x: rect.maxX - top, y: rect.minY + top), radius: top, startAngle: .degrees(0),
                     endAngle: .degrees(-90), clockwise: true)
            p.addLine(to: CGPoint(x: rect.minX + top, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.minX + top, y: rect.minY + top), radius: top, startAngle: .degrees(-90),
                     endAngle: .degrees(180), clockwise: true)
        }
        return p
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
/// told from text by more than its color; a raw view's key and string on a fill of their own.
struct DocumentStyle {
    var marker: Color
    var markerFill: Color
    var stringFill: Color

    init(_ colors: VettIDColors) {
        marker = colors.error.color
        markerFill = colors.error.color.opacity(0.14)
        stringFill = colors.secondaryContainer.color
    }
}

/// Some pieces of a document drawn as one text (a raw view's lines one under the other, each left-to-right), and read
/// by VoiceOver from the same tokens (``Spoken``).
struct DocPieceView: View {
    @Environment(\.vettIDColors) private var colors
    let pieces: [DocPiece]
    let raw: Bool

    var body: some View {
        let style = DocumentStyle(colors)
        let text = pieces.enumerated().reduce(into: AttributedString()) { out, e in
            if e.offset > 0 { out += AttributedString("\n") }
            out += Self.attributed(e.element, style, raw: raw)
        }
        Group {
            if raw {
                Text(text).font(.system(.callout, design: .monospaced))
            } else {
                Text(text).vettIDFont(.bodyLarge)
            }
        }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.disabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Spoken.text(Array(pieces.map { Spoken.of($0, raw: raw) }.joined(separator: [.app("\n")]))))
    }

    static let lrm = "\u{200E}"
    static let fsi = "\u{2068}"
    static let pdi = "\u{2069}"

    /// A piece as drawn. A raw view's line starts with a left-to-right mark, so its base direction is left-to-right
    /// whatever its isolates hold; its keys and strings sit on their fill inside their isolates.
    static func attributed(_ p: DocPiece, _ style: DocumentStyle, raw: Bool) -> AttributedString {
        var out = AttributedString(raw ? lrm : "")
        var isolated = false
        for t in p.tokens {
            switch t {
            case .punct(let s), .literal(let s): out += AttributedString(s)
            case .indent(let n): out += AttributedString(String(repeating: "  ", count: n))
            case .open:
                isolated = true
                out += AttributedString(fsi)
            case .close:
                isolated = false
                out += AttributedString(pdi)
            case .spokenQuote: break
            case .content(let s):
                var a = AttributedString(s)
                if isolated { a.backgroundColor = style.stringFill }
                out += a
            case .marker(let v):
                var a = AttributedString(ShownText.marker(v))
                a.font = .system(.body, design: .monospaced)
                a.foregroundColor = style.marker
                a.backgroundColor = style.markerFill
                a.underlineStyle = .single
                out += a
            case .lineBreak: out += AttributedString("\n")
            }
        }
        return out
    }
}

/// What VoiceOver reads on this screen, and what a braille display shows. The separation does not rest on pitch: the
/// document's text is read between quotation marks (the ones drawn, or spoken ones where none is drawn), with its own
/// `"` and `\` escaped, so no text can close them; those marks, the markers and the app's punctuation are spoken as
/// punctuation; the document's text has a pitch of its own as well, a cue only.
enum Spoken: Equatable {
    /// The app's words, at the usual pitch.
    case app(String)
    /// The app's punctuation and markers, always spoken (and shown in braille) as punctuation.
    case symbol(String)
    /// The document's own text.
    case content(String)

    /// The pitch of the document's text. UIKit's scale is 0 to 2 with 1 the usual pitch, SwiftUI's -1 to 1 with 0; 0.5
    /// differs from the usual on either.
    static let contentPitch = 0.5

    /// What a piece reads: a raw line's level first; a value's text with its `"` and `\` escaped (a raw view's already are).
    static func of(_ p: DocPiece, raw: Bool) -> [Spoken] {
        var out: [Spoken] = p.level.map { [.app(ApprovalsStrings.docLevelSpoken($0) + ", ")] } ?? []
        for t in p.tokens {
            switch t {
            case .punct(let s): out.append(.symbol(s))
            case .spokenQuote: out.append(.symbol("\""))
            case .content(let s): out.append(.content(raw ? s : escaped(s)))
            case .literal(let s): out.append(.app(s))
            case .marker(let v): out.append(.symbol(ShownText.marker(v)))
            case .lineBreak: out.append(.app("\n"))
            case .indent, .open, .close: break
            }
        }
        return out
    }

    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func plain(_ pieces: [Spoken]) -> String {
        pieces.map { p in
            switch p {
            case .app(let s), .symbol(let s), .content(let s): s
            }
        }.joined()
    }

    /// One attributed text: never a chain of concatenated texts, whose depth grows with the document.
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
#endif
