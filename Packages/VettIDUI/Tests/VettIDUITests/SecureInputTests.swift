import Foundation
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

    /// A paste-only editor (a recovery code) offers no Copy or Cut and copies nothing; a paste stays possible.
    @Test func aPasteOnlyEditorNeverCopies() {
        let v = PasteOnlyTextView()
        v.text = "7ZK3"
        v.selectedRange = NSRange(location: 0, length: 4)
        UIPasteboard.general.items = []
        #expect(!v.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        #expect(!v.canPerformAction(#selector(UIResponderStandardEditActions.cut(_:)), withSender: nil))
        v.copy(nil)
        v.cut(nil)
        #expect(UIPasteboard.general.string == nil || UIPasteboard.general.string?.isEmpty == true)
        #expect(v.text == "7ZK3")
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
}
