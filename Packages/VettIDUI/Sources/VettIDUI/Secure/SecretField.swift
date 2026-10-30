import SwiftUI
import UIKit

/// How a secret field's keyboard is set up (IOS-PLAN §6.5, ID11): no AutoFill and no "Save Password?", no
/// autocorrection, spell checking, smart quotes, dashes or inserts, no inline predictions, no capitalization.
///
/// AutoFill and the save prompt: iOS offers them for a field whose `textContentType` is a credential type (`.password`,
/// `.newPassword`, `.username`) and for a secure field next to a username-like field. These fields set the content type
/// to an empty type (not nil, which lets iOS guess), never stand beside a username field, and are emptied when they
/// leave the screen (the save prompt comes from a secure field that disappears with text in it). The device test of
/// §6.5 (submit each secret screen and check that neither the AutoFill bar nor the save prompt appears) records which
/// technique holds: this one first, then `.oneTimeCode`; `isSecureTextEntry` stays (it keeps the text out of captures
/// and the keyboard from learning), manual masking being the last resort. Not yet run on an iPhone.
@MainActor
public enum SecretInput {
    /// Applies the secret-input settings to [field]. [visible]: a secret the member reads while typing it (a recovery
    /// or setup code): an ASCII-capable keyboard; otherwise a masked field.
    public static func configure(_ field: UITextField, visible: Bool) {
        field.textContentType = UITextContentType(rawValue: "")
        field.passwordRules = nil
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.autocapitalizationType = .none
        field.inlinePredictionType = .no
        field.keyboardType = .asciiCapable
        field.isSecureTextEntry = !visible
        field.clearsOnBeginEditing = false
    }
}

/// A secret text field (the credential password): masked, with a show/hide button, and none of AutoFill, the save
/// prompt, autocorrection or keyboard learning (``SecretInput``). Callers keep the value in view-model state only.
/// Mirrors vettid-android `SecretField` (the PIN has its own keypad on iOS, ``PinKeypad``).
public struct SecretField: View {
    @Binding private var text: String
    private let label: String
    private let error: String?
    private let spokenError: String?
    private let errorPriority: Announce
    private let supporting: String?
    private let onSubmit: () -> Void
    private let focus: Bool
    @State private var shown = false
    @Environment(\.vettIDColors) private var colors

    /// [focus]: the field takes the keyboard (once, each time it turns true). The error is spoken to VoiceOver when it
    /// appears or changes, politely as on vettid-android (a check made while typing must not cut off the typing's echo);
    /// [errorPriority] `.assertive` for the result of an attempt. [spokenError]: what is said instead of an error that
    /// changes by itself (a backoff counting down), so that it is said once.
    public init(
        _ label: String, text: Binding<String>, error: String? = nil, spokenError: String? = nil,
        errorPriority: Announce = .polite, supporting: String? = nil, focus: Bool = false, onSubmit: @escaping () -> Void = {}
    ) {
        self.label = label
        _text = text
        self.error = error
        self.spokenError = spokenError
        self.errorPriority = errorPriority
        self.supporting = supporting
        self.focus = focus
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                SecretTextInput(text: $text, placeholder: label, visible: shown, focus: focus, onSubmit: onSubmit)
                    .frame(minHeight: Spacing.touchTarget)
                    .accessibilityLabel(label)
                Button { shown.toggle() } label: {
                    Image(systemName: shown ? "eye.slash" : "eye").foregroundStyle(colors.onSurfaceVariant)
                }
                .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                .accessibilityLabel(shown ? UIStrings.hideSecret(label) : UIStrings.showSecret(label))
            }
            .padding(.leading, Spacing.l)
            .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(error == nil ? colors.outline : colors.error))
            if let error {
                Text(error).vettIDFont(.bodySmall).foregroundStyle(colors.error).announced(spokenError ?? error, errorPriority)
            }
            if let supporting { Text(supporting).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant) }
        }
    }
}

/// A secret the member must see while typing it (a recovery phrase, a setup or transfer code): visible, ASCII-capable
/// keyboard, the same keyboard settings as ``SecretField``. [placeholder] replaces the label inside the empty field;
/// [capitalization] (none by default) and [monospaced] suit a code; [isError] outlines it in the error colour. Mirrors
/// vettid-android `visibleSecretKeyboard`.
public struct VisibleSecretField: View {
    @Binding private var text: String
    private let label: String
    private let style: SecretTextInput.Style
    private let isError: Bool
    private let focus: Bool
    private let accept: SecretTextInput.Accept?
    private let onSubmit: () -> Void
    @Environment(\.vettIDColors) private var colors

    /// [keyboard]: an ASCII-capable keyboard unless a digit pad suits the value (a number, a phone number, a date), which
    /// has no suggestions either. [focus]: the field takes the keyboard (once, each time it turns true). [accept]: what the
    /// field keeps of an edit (the value's format, from the text before and the text typed), shown in the field at once.
    public init(
        _ label: String,
        text: Binding<String>,
        placeholder: String? = nil,
        capitalization: UITextAutocapitalizationType = .none,
        monospaced: Bool = false,
        keyboard: UIKeyboardType = .asciiCapable,
        isError: Bool = false,
        focus: Bool = false,
        accept: SecretTextInput.Accept? = nil,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.label = label
        _text = text
        style = SecretTextInput.Style(
            placeholder: placeholder ?? label, capitalization: capitalization, monospaced: monospaced, keyboard: keyboard
        )
        self.isError = isError
        self.focus = focus
        self.accept = accept
        self.onSubmit = onSubmit
    }

    public var body: some View {
        SecretTextInput(
            text: $text, placeholder: style.placeholder, visible: true, style: style, focus: focus, accept: accept, onSubmit: onSubmit
        )
            .frame(minHeight: Spacing.touchTarget)
            .padding(.horizontal, Spacing.l)
            .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(isError ? colors.error : colors.outline))
            .accessibilityLabel(label)
    }
}

/// The `UITextField` behind the secret fields.
public struct SecretTextInput: UIViewRepresentable {
    /// What a field keeps of an edit: from the text before and the text typed, the value (its format applied, or the
    /// text before when the edit is refused).
    public typealias Accept = (_ old: String, _ typed: String) -> String

    /// How a visible code field looks: what the empty field shows, its capitalization, a monospaced font.
    struct Style {
        var placeholder: String
        var capitalization: UITextAutocapitalizationType = .none
        var monospaced = false
        var keyboard: UIKeyboardType = .asciiCapable
    }

    @Binding var text: String
    let placeholder: String
    let visible: Bool
    var style: Style?
    var focus = false
    var accept: Accept?
    let onSubmit: () -> Void

    public final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SecretTextInput
        /// The focus asked for was given (asked again only after it turned false).
        var focused = false

        init(_ parent: SecretTextInput) { self.parent = parent }

        /// An edit: what the field keeps of it ([accept]) is the value, and the field shows it at once (a refused or
        /// filtered edit leaves the model as it was, so nothing else would put the field right).
        @objc func changed(_ field: UITextField) {
            let typed = field.text ?? ""
            let kept = parent.accept?(parent.text, typed) ?? typed
            if kept != typed { SecretTextInput.show(kept, in: field) }
            parent.text = kept
        }

        public func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }
    }

    /// Shows [kept] in [field], the cursor as far from the end as it was.
    static func show(_ kept: String, in field: UITextField) {
        let fromEnd = field.selectedTextRange.map { field.offset(from: $0.end, to: field.endOfDocument) } ?? 0
        field.text = kept
        if let p = field.position(from: field.endOfDocument, offset: -min(fromEnd, kept.utf16.count)) {
            field.selectedTextRange = field.textRange(from: p, to: p)
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
        SecretInput.configure(f, visible: visible)
        f.placeholder = placeholder
        if let style {
            f.autocapitalizationType = style.capitalization
            f.keyboardType = style.keyboard
            if style.monospaced {
                // Title 3 at the default text size, scaled with the member's text size.
                f.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .monospacedSystemFont(ofSize: 20, weight: .regular))
                f.adjustsFontForContentSizeCategory = true
            }
        }
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }

    public func updateUIView(_ f: UITextField, context: Context) {
        context.coordinator.parent = self
        SecretFocus.request(focus, f, &context.coordinator.focused)
        if f.isSecureTextEntry == visible {
            // Switching secure entry makes iOS clear the field on the next keystroke; setting the text again keeps it.
            f.isSecureTextEntry = !visible
            f.text = text
        }
        if f.text != text { f.text = text }
    }

    /// Leaves no text behind in a secure field that goes (the save prompt's trigger).
    public static func dismantleUIView(_ f: UITextField, coordinator: Coordinator) { f.text = "" }
}

/// Gives a UIKit text input the keyboard once when [focus] turns true (as SwiftUI's `focused` does for its own fields).
@MainActor
enum SecretFocus {
    static func request(_ focus: Bool, _ view: UIView, _ given: inout Bool) {
        guard focus else { return given = false }
        guard !given else { return }
        given = true
        DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() }
    }
}
