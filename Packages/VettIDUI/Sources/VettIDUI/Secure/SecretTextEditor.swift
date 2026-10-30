import SwiftUI
import UIKit

/// A multi-line secret the member sees while typing it (a secret or critical item's notes or long text, a recovery
/// phrase): a `UITextView` with the keyboard settings of ``SecretInput`` (no AutoFill or "Save Password?", no
/// autocorrection, spell checking, predictions or smart punctuation, an ASCII-capable keyboard). [placeholder] shows
/// while it is empty. Mirrors vettid-android's `visibleSecretKeyboard` on a multi-line field.
public struct SecretTextEditor: View {
    @Binding private var text: String
    private let label: String
    private let placeholder: String?
    private let isError: Bool
    private let focus: Bool
    private let pasteOnly: Bool
    private let onSubmit: (() -> Void)?
    private let keeps: ((Character) -> Bool)?
    private let monospaced: Bool
    private let onTextWidth: ((CGFloat) -> Void)?
    @Environment(\.vettIDColors) private var colors

    /// [focus]: the editor takes the keyboard (once, each time it turns true). [pasteOnly]: the text menu offers no Copy or
    /// Cut, so what is typed here never reaches the clipboard (a recovery code, VAULT-MESSAGING §11.11.10: "the code does
    /// not go to a clipboard"); a paste is allowed. A paste-only editor also shows the model's text again when the model refuses
    /// what was typed, and keeps the cursor after the same characters when the text is drawn again (a text in groups); [keeps] says
    /// which characters the model keeps (default: those that are not whitespace). [onSubmit]: the Return key calls it instead of
    /// adding a line (and is labelled Done). [monospaced]: every character as wide as the next (a code, as vettid-android
    /// draws it; read when the editor is made). [onTextWidth]: told the width a line of text has, as it changes (a text in rows can choose what fits).
    public init(
        _ label: String, text: Binding<String>, placeholder: String? = nil, isError: Bool = false, focus: Bool = false,
        pasteOnly: Bool = false, onSubmit: (() -> Void)? = nil,
        keeps: ((Character) -> Bool)? = nil, monospaced: Bool = false, onTextWidth: ((CGFloat) -> Void)? = nil
    ) {
        self.label = label
        _text = text
        self.placeholder = placeholder
        self.isError = isError
        self.focus = focus
        self.pasteOnly = pasteOnly
        self.onSubmit = onSubmit
        self.keeps = keeps
        self.monospaced = monospaced
        self.onTextWidth = onTextWidth
    }

    /// The editor's font: the body style, scaled for Dynamic Type ([traits]: for a given size; default: the current one).
    public static func font(monospaced: Bool, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        guard monospaced else { return .preferredFont(forTextStyle: .body, compatibleWith: traits) }
        let base = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        return UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .monospacedSystemFont(ofSize: base.pointSize, weight: .regular), compatibleWith: traits)
    }

    public var body: some View {
        SecretTextView(text: $text, focus: focus, pasteOnly: pasteOnly, onSubmit: onSubmit, keeps: keeps, monospaced: monospaced)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                onTextWidth?(width - 2 * SecretTextView.lineFragmentPadding)
            }
            .frame(minHeight: Spacing.touchTarget * 2)
            .overlay(alignment: .topLeading) {
                if text.isEmpty, let placeholder {
                    Text(placeholder)
                        .vettIDFont(.bodyLarge)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .padding(.top, Spacing.s)
                        .padding(.leading, Spacing.xs)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(isError ? colors.error : colors.outline))
            .accessibilityLabel(label)
    }
}

/// The `UITextView` behind ``SecretTextEditor``.
struct SecretTextView: UIViewRepresentable {
    @Binding var text: String
    var focus = false
    var pasteOnly = false
    var onSubmit: (() -> Void)?
    var keeps: ((Character) -> Bool)?
    var monospaced = false

    /// The space each side of a line, inside the view.
    static let lineFragmentPadding: CGFloat = 5

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SecretTextView
        var focused = false

        init(_ parent: SecretTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text ?? ""
            // A model that refused what was typed (and so did not change) is not redrawn by SwiftUI: the view shows the
            // model's text again once the change is through.
            guard parent.pasteOnly else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, view.text != self.parent.text else { return }
                SecretTextView.show(self.parent.text, in: view, keeps: self.parent.keeps)
            }
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", let submit = parent.onSubmit else { return true }
            submit()
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let v = pasteOnly ? PasteOnlyTextView() : UITextView()
        v.textContentType = UITextContentType(rawValue: "")
        v.autocorrectionType = .no
        v.spellCheckingType = .no
        v.smartQuotesType = .no
        v.smartDashesType = .no
        v.smartInsertDeleteType = .no
        v.autocapitalizationType = .none
        v.inlinePredictionType = .no
        v.keyboardType = .asciiCapable
        if onSubmit != nil { v.returnKeyType = .done }
        v.font = SecretTextEditor.font(monospaced: monospaced)
        v.textContainer.lineFragmentPadding = Self.lineFragmentPadding
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.isScrollEnabled = false
        v.delegate = context.coordinator
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        if v.text != text {
            if pasteOnly { Self.show(text, in: v, keeps: keeps) } else { v.text = text }
        }
        SecretFocus.request(focus, v, &context.coordinator.focused)
    }

    /// [text] in [v], the cursor kept after the same number of characters that [keeps] (default: not whitespace) in what was
    /// there before it (a text that is redrawn in groups, or without what the model refused, keeps the member's place). A view
    /// that is not being edited puts the cursor at the end.
    static func show(_ text: String, in v: UITextView, keeps: ((Character) -> Bool)? = nil) {
        let kept = keeps ?? { !$0.isWhitespace }
        let before = v.text ?? ""
        let editing = v.isFirstResponder || v.selectedRange.length > 0 || v.selectedRange.location < (before as NSString).length
        let cursor = min(v.selectedRange.location, (before as NSString).length)
        let significant = (before as NSString).substring(to: cursor).filter(kept).count
        v.text = text
        guard editing else {
            v.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            return
        }
        var seen = 0
        var offset = 0
        for character in text {
            if seen == significant { break }
            offset += character.utf16.count
            if kept(character) { seen += 1 }
        }
        v.selectedRange = NSRange(location: offset, length: 0)
    }

    /// As wide as offered, as tall as its text.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fit.height)
    }

    /// Leaves no text behind in a view that goes.
    static func dismantleUIView(_ v: UITextView, coordinator: Coordinator) { v.text = "" }
}

/// A text view whose menu and shortcuts only paste into it, select and delete: no Copy, Cut, Share, Look Up, Translate or other
/// action that would hand its text to another app or the clipboard, no drag out, no Writing Tools.
final class PasteOnlyTextView: UITextView {
    private static let allowed: [Selector] = [
        #selector(UIResponderStandardEditActions.paste(_:)), #selector(UIResponderStandardEditActions.select(_:)),
        #selector(UIResponderStandardEditActions.selectAll(_:)), #selector(UIResponderStandardEditActions.delete(_:)),
    ]

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        textDragInteraction?.isEnabled = false
        if #available(iOS 18.0, *) { writingToolsBehavior = .none }
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        Self.allowed.contains(action) && super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {}
    override func cut(_ sender: Any?) {}
}
