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
    @Environment(\.vettIDColors) private var colors

    public init(_ label: String, text: Binding<String>, placeholder: String? = nil, isError: Bool = false) {
        self.label = label
        _text = text
        self.placeholder = placeholder
        self.isError = isError
    }

    public var body: some View {
        SecretTextView(text: $text)
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

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SecretTextView

        init(_ parent: SecretTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) { parent.text = view.text ?? "" }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
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
        if v.text != text { v.text = text }
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
