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
    @Environment(\.dynamicTypeSize) private var typeSize
    let step: DocumentStep
    /// Counts the documents shown: the same document shown again is followed again from nothing seen.
    var generation = 0
    /// VoiceOver is on (read by the screen and passed in, so that turning it on or off cuts the document again).
    var voiceOver = false
    let name: String?
    let seen: Bool
    let onRetry: @MainActor () -> Void
    /// The whole of the document of that hash, in that generation, has been on screen.
    let onSeenWhole: @MainActor (String, Int) -> Void
    /// TEST ONLY: each row's height in pixels as it is measured.
    var onRowPixels: (@MainActor (CGFloat) -> Void)?
    /// TEST ONLY: whether the notice shows, each time that changes.
    var onNotice: (@MainActor (Bool) -> Void)?
    /// A row is too tall to be drawn even at the smallest cutting: the document cannot be approved here, and the screen
    /// says so.
    @State private var tooTall = false
    /// Times the cutting was halved because a row was too tall to be drawn: rows are cut again, smaller, before the
    /// screen ever gives up (``smallestPiece``).
    @State private var shrink = 0
    /// VoiceOver as the screen last saw it (``rowTooTall(_:)`` compares against it).
    @State private var liveVoiceOver = false

    /// The fewest characters a piece is cut to.
    static let smallestPiece = 10

    /// What it shows: the screen's one-second countdown does not lay a large document out again (`.equatable()`).
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.step == b.step && a.generation == b.generation && a.voiceOver == b.voiceOver && a.name == b.name && a.seen == b.seen
    }

    /// What makes the rows another view.
    struct RowsID: Hashable {
        var sha256: String
        var generation: Int
        var cutting: Cutting
    }

    /// The cutting: with VoiceOver, pieces small enough (in characters and kept line breaks) that each fits on the screen
    /// at the largest text size, so moving from one element to the next brings every part on screen.
    var cutting: Cutting { Self.cutting(voiceOver: voiceOver, shrink: shrink) }

    static func cutting(voiceOver: Bool, shrink: Int) -> Cutting {
        let base = voiceOver
            ? Cutting(max: 30, maxBreaks: 4, perRow: 1) : Cutting(max: ShownText.pieceCharacters, maxBreaks: .max, perRow: 20)
        guard shrink > 0 else { return base }
        return Cutting(
            max: Swift.max(base.max >> shrink, smallestPiece), maxBreaks: Swift.max(Swift.min(base.maxBreaks, 8) >> shrink, 1),
            perRow: Swift.max(base.perRow >> shrink, 1)
        )
    }

    /// A row too tall to be drawn, reported by rows of [reported] cutting: cut again smaller, or, at the smallest
    /// cutting, say so. A report from rows of an earlier cutting (several in one pass) is stale and changes nothing, so
    /// the smallest cutting is always laid out before the screen says so.
    private func rowTooTall(_ reported: Cutting) {
        // The cutting now, from state (the closure that reports may hold an earlier copy of this view).
        let current = Self.cutting(voiceOver: liveVoiceOver, shrink: shrink)
        guard reported == current else { return }
        if current.max > Self.smallestPiece {
            shrink += 1
        } else if !tooTall {
            tooTall = true
        }
    }

    /// The usual cutting again, nothing held: on another document, VoiceOver turned on or off, another text size or
    /// visible height.
    private func resetCutting() {
        shrink = 0
        tooTall = false
    }

    /// How a document is cut into rows: characters and kept line breaks to a piece, raw pieces to a row.
    struct Cutting: Hashable {
        var max: Int
        var maxBreaks: Int
        var perRow: Int
    }

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
                let cut = cutting
                DocumentRows(rows: rows(p), onSeenWhole: { onSeenWhole(d.sha256, generation) }, onTooTall: { rowTooTall(cut) },
                             onRowPixels: onRowPixels, fitScreen: voiceOver, onScreenHeight: { _ in resetCutting() })
                    // Another document, the same shown again, or another cutting is another view: its coverage starts
                    // again (rows of one cutting are not rows of another).
                    .id(RowsID(sha256: d.sha256, generation: generation, cutting: cutting))
                // Never beside an enabled Approve: once the document has been seen whole, nothing is held.
                if tooTall, !seen {
                    // Never silent: a row a phone would draw blank is never counted as seen, so Approve stays off.
                    NoticeCard(.warning, title: ApprovalsStrings.docTooTall, message: ApprovalsStrings.docTooTallBody, announce: .polite)
                        .accessibilityIdentifier("document_too_tall")
                } else if !seen {
                    Text(ApprovalsStrings.docReadToEnd).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                        .accessibilityIdentifier("document_read_to_end")
                }
            }
        }
        .padding(.top, Spacing.l)
        // Another document starts from the usual cutting.
        .onChange(of: generation) { resetCutting() }
        .onChange(of: voiceOver, initial: true) { _, now in
            if liveVoiceOver != now { resetCutting() }
            liveVoiceOver = now
        }
        .onChange(of: tooTall && !seen) { _, shows in onNotice?(shows) }
        .onChange(of: typeSize) { resetCutting() }
    }

    /// The document as rows, each small: the parts under their labels, and every value of any length in pieces
    /// (``DocPiece``), so that the largest document is drawn a few rows at a time and every row is drawn whole.
    private func rows(_ p: DocumentPresentation) -> [DocRow] {
        let d = DocRows(max: cutting.max, maxBreaks: cutting.maxBreaks)
        var r: [DocRow] = [DocRows.heading(ApprovalsStrings.docAsked)]
        switch p.asked {
        case .known(let a): r.append(DocRows.block { Text(Self.title(a)).vettIDFont(.bodyLarge) })
        case .unknown(let action):
            r += d.value(ShownText(action))
            let who = AccountNames.isolateOrNull(name) ?? ApprovalsStrings.aConnection
            r.append(DocRow(
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
            r += d.raw(lines, perRow: cutting.perRow)
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
    let rows: [DocRow]
    let onSeenWhole: @MainActor () -> Void
    var onTooTall: @MainActor () -> Void = {}
    var onRowPixels: (@MainActor (CGFloat) -> Void)?
    /// With VoiceOver, a row taller than the visible area is too tall as well: moving from one element to the next would
    /// leave part of it never on screen.
    var fitScreen = false
    /// The scroll view's visible height changed (rotation, the keyboard): the cutting starts again.
    var onScreenHeight: @MainActor (CGFloat) -> Void = { _ in }
    @State private var seen: Set<Int> = []
    @State private var screen: CGFloat = 0

    /// The tallest a row may be, in pixels, and still count as seen. An iPhone 15 draws a document's row of 48,000 pixels
    /// to its end and a single text of 315,000 blank (the app's ``ApprovalDocumentDrawingTests`` measure it); a row over
    /// this, far under both and so also for smaller phones, is
    /// never seen, so a document that could draw blank is never approved (fail closed): it is cut again smaller, and at
    /// the smallest cutting the screen says so. Rows are cut far below it.
    static let maxRowPixels: CGFloat = 50_000

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                rows[i].view.clipped()
                    .modifier(RowSeen(
                        content: rows[i].content, onWhole: { rowSeen(i) }, onTooTall: onTooTall, onPixels: onRowPixels,
                        fitScreen: fitScreen,
                        onScreen: { h in
                            guard abs(h - screen) > 1 else { return }
                            if screen > 0 { onScreenHeight(h) }
                            screen = h
                        }
                    ))
            }
        }
    }

    private func rowSeen(_ i: Int) {
        guard rows.indices.contains(i), !seen.contains(i) else { return }
        seen.insert(i)
        if seen.isSuperset(of: rows.indices) { onSeenWhole() }
    }
}

/// Says once that the whole of a row has been on screen in the enclosing scroll view.
struct RowSeen: ViewModifier {
    @Environment(\.displayScale) private var scale
    /// The row holds the document's text (a value's piece, raw lines), not the app's own words: only such a row must fit
    /// the screen under VoiceOver.
    var content = false
    let onWhole: @MainActor () -> Void
    var onTooTall: @MainActor () -> Void = {}
    var onPixels: (@MainActor (CGFloat) -> Void)?
    var fitScreen = false
    var onScreen: @MainActor (CGFloat) -> Void = { _ in }
    @State private var coverage = SeenCoverage()

    struct Seen: Equatable {
        var visible: ClosedRange<CGFloat>?
        var height: CGFloat
        /// The scroll view's visible height.
        var screen: CGFloat
    }

    /// The part of the row on screen, in its own coordinates; none without a scroll view to measure against.
    static func seen(_ g: GeometryProxy) -> Seen {
        let h = g.size.height
        guard let b = g.bounds(of: .scrollView) else { return Seen(visible: nil, height: h, screen: 0) }
        let top = max(b.minY, 0), bottom = min(b.maxY, h)
        return Seen(visible: top <= bottom ? top...bottom : nil, height: h, screen: b.height)
    }

    func body(content row: Content) -> some View {
        row.background(
            GeometryReader { g in
                Color.clear.onChange(of: Self.seen(g), initial: true) { _, now in
                    let pixels = now.height * scale
                    onPixels?(pixels)
                    if now.screen > 0 { onScreen(now.screen) }
                    guard pixels <= DocumentRows.maxRowPixels, !(fitScreen && content) || now.screen == 0 || now.height <= now.screen
                    else { return onTooTall() }
                    coverage.saw(now.visible, height: now.height)
                    if coverage.whole { onWhole() }
                }
            }
        )
    }
}

/// A row of a document: its view, and whether it holds the document's text (a value's piece, raw lines) rather than
/// the app's own words (headings, labels, notices).
struct DocRow {
    let view: AnyView
    let content: Bool

    init(_ view: some View, content: Bool = false) {
        self.view = AnyView(view)
        self.content = content
    }

    /// The row with room above it.
    func padded(_ top: CGFloat) -> DocRow { DocRow(view.padding(.top, top), content: content) }
}

/// The rows of each part of a document, built from ``DocPiece``s of at most [max] characters.
@MainActor
struct DocRows {
    let max: Int
    var maxBreaks: Int = .max

    static func heading(_ label: String) -> DocRow {
        DocRow(DocHeading(label: label).padding(.top, Spacing.l).padding(.bottom, Spacing.s))
    }

    static func label(_ text: String) -> DocRow {
        DocRow(FieldLabel(text: text).padding(.top, Spacing.m).padding(.bottom, Spacing.xs))
    }

    static func note(_ text: String) -> DocRow { DocRow(DocNote(text: text).padding(.top, Spacing.s)) }

    /// A value in a block of its own, as rows of pieces that join into one block.
    func value(_ t: ShownText) -> [DocRow] {
        let pieces = DocPiece.value(t, max: max, maxBreaks: maxBreaks)
        return pieces.indices.map { i in
            DocRow(ValuePiece(first: i == 0, last: i == pieces.count - 1) { DocPieceView(pieces: [pieces[i]], raw: false) }, content: true)
        }
    }

    /// A short value of the app's own words or a time, in a block of its own.
    static func block(@ViewBuilder _ content: @escaping @MainActor () -> some View) -> DocRow {
        DocRow(ValuePiece(first: true, last: true) { content() })
    }

    func proposal(_ f: DocumentPresentation.ProposalForm) -> [DocRow] {
        var r: [DocRow] = [Self.label(ApprovalsStrings.docFieldTitle)] + value(f.title)
        r.append(Self.label(ApprovalsStrings.docFieldMotion))
        if let text = f.text { r += value(text) } else { r.append(DocRow(FieldLabel(text: ApprovalsStrings.docNone))) }
        r.append(Self.label(ApprovalsStrings.docFieldChoices))
        for (i, c) in f.choices.enumerated() {
            r += value(c).enumerated().map { j, v in j == 0 && i > 0 ? v.padded(Spacing.xs) : v }
        }
        r.append(DocRow(
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
            r += value(text).enumerated().map { j, v in j == 0 ? v.padded(Spacing.xs) : v }
        }
        r.append(Self.block { Text(f.binding ? ApprovalsStrings.docBinding : ApprovalsStrings.docAdvisory).vettIDFont(.bodyLarge) }
            .padded(Spacing.m))
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

    func extend(_ f: DocumentPresentation.ExtendForm) -> [DocRow] {
        [Self.label(ApprovalsStrings.docFieldVote)] + value(f.proposalID)
            + [Self.label(ApprovalsStrings.docFieldNewClose), Self.block { TimeValue(seconds: f.closesAt) }]
            + [Self.label(ApprovalsStrings.docFieldOutageFrom), Self.block { TimeValue(seconds: f.outageFrom) }]
            + [Self.label(ApprovalsStrings.docFieldOutageTo), Self.block { TimeValue(seconds: f.outageTo) }]
            + [Self.label(ApprovalsStrings.docFieldReportedBy)] + value(f.outageSource)
    }

    /// The raw view as rows of a few pieces each (one with VoiceOver), joining into one block.
    func raw(_ lines: [DocumentPresentation.RawLine], perRow: Int) -> [DocRow] {
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
            DocRow(
                ValuePiece(first: i == 0, last: i == rows.count - 1) { DocPieceView(pieces: rows[i], raw: true) }
                    .environment(\.layoutDirection, .leftToRight),
                content: true
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
    var continuation: Color

    init(_ colors: VettIDColors) {
        continuation = colors.primary.color
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

    // One case per kind of token.
    // swiftlint:disable cyclomatic_complexity

    /// A piece as drawn. A raw view's line starts with a left-to-right mark, so its base direction is left-to-right
    /// whatever its isolates hold; its keys and strings sit on their fill inside their isolates.
    static func attributed(_ p: DocPiece, _ style: DocumentStyle, raw: Bool) -> AttributedString {
        var out = AttributedString(raw ? lrm : "")
        var isolated = false
        for t in p.tokens {
            switch t {
            case .punct(let s) where s == DocPiece.continued || s == DocPiece.continues:
                // The app's continuation mark, in a style of its own (no text can draw it: it is a marker there); after
                // a white space, without another.
                let after = out.characters.last?.isWhitespace == true
                var a = AttributedString(after ? s.trimmingCharacters(in: .whitespaces) + (s == DocPiece.continued ? " " : "") : s)
                a.foregroundColor = style.continuation
                a.inlinePresentationIntent = .stronglyEmphasized
                out += a
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
    // swiftlint:enable cyclomatic_complexity
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
