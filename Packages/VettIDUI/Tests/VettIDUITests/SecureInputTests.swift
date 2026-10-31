import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import VettIDUI

/// IOS-PLAN §6.4 and §6.5 in the components: the secret fields' keyboard settings, the secure layer's self-check, the
/// PIN buffer and the local, expiring pasteboard.
@MainActor
@Suite struct SecureInputTests {
    @Test func secretFieldsTurnOffAutoFillAndKeyboardLearning() {
        for visible in [false, true] {
            let f = UITextField()
            SecretInput.configure(f, visible: visible)
            #expect(f.textContentType == UITextContentType(rawValue: ""))
            #expect(f.textContentType != .password && f.textContentType != .newPassword && f.textContentType != .username)
            #expect(f.autocorrectionType == .no && f.spellCheckingType == .no)
            #expect(f.smartQuotesType == .no && f.smartDashesType == .no && f.smartInsertDeleteType == .no)
            #expect(f.inlinePredictionType == .no && f.autocapitalizationType == .none)
            #expect(f.keyboardType == .asciiCapable)
            #expect(f.isSecureTextEntry == !visible)
        }
    }

    /// A paste-only editor (a recovery code) offers no Copy, Cut, Share, Look Up or Translate and copies nothing; it has no drag
    /// out. (The general pasteboard is not touched: `copy` and `cut` do nothing.)
    @Test func aPasteOnlyEditorNeverCopies() {
        let v = PasteOnlyTextView()
        v.text = "7ZK3"
        v.selectedRange = NSRange(location: 0, length: 4)
        for action in [
            #selector(UIResponderStandardEditActions.copy(_:)), #selector(UIResponderStandardEditActions.cut(_:)),
            Selector(("_share:")), Selector(("_lookup:")), Selector(("_translate:")), Selector(("_define:")),
            #selector(UIResponderStandardEditActions.toggleBoldface(_:)),
        ] {
            #expect(!v.canPerformAction(action, withSender: nil), "\(action)")
        }
        v.copy(nil)
        v.cut(nil)
        #expect(v.text == "7ZK3")
        #expect(v.textDragInteraction?.isEnabled != true)
        if #available(iOS 18.0, *) { #expect(v.writingToolsBehavior == .none) }
    }

    /// The cursor stays after the same characters that the model keeps (a refused letter and a separator do not count), and a
    /// view that is not being edited puts it at the end.
    @Test func theCursorKeepsItsPlace() {
        let keeps: (Character) -> Bool = { $0.isLetter && $0 != "U" || $0.isNumber }
        let v = UITextView()
        v.text = "7ZUK3"
        v.selectedRange = NSRange(location: 3, length: 0)
        SecretTextView.show("7ZK3", in: v, keeps: keeps)
        #expect(v.text == "7ZK3" && v.selectedRange.location == 2, "a refused letter before the cursor is not counted")
        v.text = "7ZK-3"
        v.selectedRange = NSRange(location: 4, length: 0)
        SecretTextView.show("7ZK3", in: v, keeps: keeps)
        #expect(v.selectedRange.location == 3, "a pasted dash is not counted")
        let fresh = UITextView()
        SecretTextView.show("7ZK3", in: fresh, keeps: keeps)
        #expect(fresh.selectedRange.location == 4, "not being edited: at the end")
    }

    /// An editor that is not paste-only writes the model's text as it always did: the cursor goes to the end.
    @Test func anOrdinaryEditorKeepsTheOldBehaviour() async throws {
        let box = TextBox()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: EditorHost(box: box))
        window.isHidden = false
        window.layoutIfNeeded()
        func editor(_ v: UIView) -> UITextView? { (v as? UITextView) ?? v.subviews.lazy.compactMap(editor).first }
        let v = try #require(editor(window))
        box.text = "line one\nline two"
        for _ in 0..<50 where v.text != box.text { try await Task.sleep(for: .milliseconds(20)) }
        #expect(v.text == "line one\nline two" && v.selectedRange.location == (v.text as NSString).length)
        window.isHidden = true
    }

    /// The undocumented layer exists on this iOS (the self-check); without it the container shows plain content.
    @Test func theSecureLayerSelfCheck() {
        #expect(SecureLayer.isAvailable)
        let layer = SecureLayer.make()
        #expect(layer?.canvas.subviews.isEmpty == true)
        #expect(layer?.canvas.isUserInteractionEnabled == true)
    }

    @Test func thePinBufferHoldsDigitsAndForgetsThem() {
        let b = PinBuffer()
        for d in [1, 2, 3, 4, 5, 6] { b.append(d) }
        b.append(12) // not a digit
        #expect(b.count == 6)
        b.deleteLast()
        #expect(b.count == 5)
        b.append(9)
        #expect(b.take() == "123459")
        #expect(b.count == 0)
        for _ in 0..<40 { b.append(7) }
        #expect(b.count == PinBuffer.maxDigits)
        b.clear()
        #expect(b.take() == "")
    }

    @Test func aCopiedSecretIsLocalAndExpires() throws {
        let board = try #require(UIPasteboard(name: UIPasteboard.Name("vettid.test.\(UUID().uuidString)"), create: true))
        SecurePasteboard.copy("ABCD-EFGH", lifetime: 60, pasteboard: board)
        #expect(board.string == "ABCD-EFGH")
        SecurePasteboard.copy("gone", lifetime: -1, pasteboard: board)
        #expect(board.string == nil) // already expired
        UIPasteboard.remove(withName: board.name)
    }

    @Test func theCoverAndTheCaptureTextRender() {
        let cover = UIHostingController(rootView: PrivacyCover())
        cover.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        cover.view.layoutIfNeeded()
        let hidden = UIHostingController(rootView: CaptureHiddenView())
        hidden.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        hidden.view.layoutIfNeeded()
        #expect(UIStrings.captureHidden == "Hidden while your screen is being recorded or shared.")
    }

    /// The secret fields' text and placeholder (their label) follow the member's text size, in the type scale's body face
    /// (Inter), as the labels around them do; a code keeps its monospaced face, also scaled.
    @Test func theSecretFieldsFollowTheTextSize() throws {
        let standard = UITraitCollection(preferredContentSizeCategory: .large)
        let largest = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        for monospaced in [false, true] {
            let small = SecretTextInput.font(monospaced: monospaced, compatibleWith: standard)
            let large = SecretTextInput.font(monospaced: monospaced, compatibleWith: largest)
            #expect(large.pointSize > small.pointSize * 2, "monospaced: \(monospaced)")
        }
        let body = SecretTextInput.font(monospaced: false, compatibleWith: standard)
        #expect(body.familyName.hasPrefix("Inter"))
        #expect(body.pointSize == 16, "the type scale's bodyLarge at the default size")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: VStack {
            SecretField("Password", text: .constant(""))
            VisibleSecretField("Code", text: .constant(""))
            VisibleSecretField("Code", text: .constant(""), monospaced: true)
        })
        window.isHidden = false
        window.layoutIfNeeded()
        let fields = textFields(in: window)
        #expect(fields.count == 3)
        for f in fields {
            #expect(f.adjustsFontForContentSizeCategory)
            let monospaced = f.font?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true
            #expect(f.font?.familyName.hasPrefix("Inter") == true || monospaced)
        }
        window.isHidden = true
    }

    private func textFields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }
}

@MainActor
@Observable
private final class TextBox {
    var text = ""
}

private struct EditorHost: View {
    let box: TextBox

    var body: some View {
        let current = box.text // read here, so a change draws the editor again
        SecretTextEditor("note", text: Binding(get: { current }, set: { box.text = $0 }))
    }
}
