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
    @Environment(\.vettIDColors) private var colors

    /// [focus]: the editor takes the keyboard (once, each time it turns true). [pasteOnly]: the text menu offers no Copy or
    /// Cut, so what is typed here never reaches the clipboard (a recovery code, VAULT-MESSAGING §11.11.10: "the code does
    /// not go to a clipboard"); a paste is allowed. A paste-only editor also shows the model's text again when the model refuses
    /// what was typed. [onSubmit]: the Return key calls it instead of adding a line.
    public init(
        _ label: String, text: Binding<String>, placeholder: String? = nil, isError: Bool = false, focus: Bool = false,
        pasteOnly: Bool = false, onSubmit: (() -> Void)? = nil
    ) {
        self.label = label
        _text = text
        self.placeholder = placeholder
        self.isError = isError
        self.focus = focus
        self.pasteOnly = pasteOnly
        self.onSubmit = onSubmit
    }

    public var body: some View {
        SecretTextView(text: $text, focus: focus, pasteOnly: pasteOnly, onSubmit: onSubmit)
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
                SecretTextView.show(self.parent.text, in: view)
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
        v.font = UIFont.preferredFont(forTextStyle: .body)
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
        if v.text != text { Self.show(text, in: v) }
        SecretFocus.request(focus, v, &context.coordinator.focused)
    }

    /// [text] in [v], the cursor kept after the same number of characters that are not whitespace (a text that is redrawn in
    /// groups keeps the member's place).
    static func show(_ text: String, in v: UITextView) {
        let before = v.text ?? ""
        let cursor = min(v.selectedRange.location, (before as NSString).length)
        let significant = (before as NSString).substring(to: cursor).filter { !$0.isWhitespace }.count
        v.text = text
        var seen = 0
        var offset = 0
        for character in text {
            if seen == significant { break }
            offset += character.utf16.count
            if !character.isWhitespace { seen += 1 }
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
