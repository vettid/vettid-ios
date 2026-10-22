#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
@testable import VettIDItems
@testable import VettIDItemsUI
@testable import VettIDUI

/// A secret input shows what the value keeps of an edit at once: a character a phone number, a date or a one-time code
/// seed cannot hold never stays in the field (the model does not change, so nothing else would put the field right).
@MainActor
@Suite struct SecretInputFilterTests {
    /// The value behind the field.
    final class Value {
        var text: String
        init(_ text: String) { self.text = text }
    }

    /// Types [typed] into a field holding [value] with [accept]: the field's text after the edit, and the value.
    private func edit(_ value: Value, typed: String, accept: @escaping SecretTextInput.Accept) -> (shown: String, kept: String) {
        let input = SecretTextInput(
            text: Binding(get: { value.text }, set: { value.text = $0 }), placeholder: "", visible: true, accept: accept, onSubmit: {}
        )
        let field = UITextField()
        field.text = typed
        input.makeCoordinator().changed(field)
        return (field.text ?? "", value.text)
    }

    @Test func aPhoneNumberKeepsOnlyItsCharacters() {
        let v = Value("+4420")
        let r = edit(v, typed: "+4420y", accept: ValueEditor.accept(FieldKinds.phone))
        #expect(r.shown == "+4420" && r.kept == "+4420")
    }

    @Test func aDateRefusesWhatNoDateCanBeginWith() {
        let v = Value("2031")
        // A letter never gets in; a 2 after the year (month 2x) is refused: the field keeps the date so far.
        var r = edit(v, typed: "2031x", accept: ValueEditor.acceptDate(monthOnly: false))
        #expect(r.shown == "2031" && r.kept == "2031")
        r = edit(v, typed: "20312", accept: ValueEditor.acceptDate(monthOnly: false))
        #expect(r.shown == "2031" && r.kept == "2031")
        r = edit(v, typed: "20310", accept: ValueEditor.acceptDate(monthOnly: false))
        #expect(r.shown == "2031-0" && r.kept == "2031-0")
    }

    @Test func aSeedIsBase32InUpperCase() {
        let v = Value("")
        let r = edit(v, typed: "jbsw y3dp", accept: ValueEditor.accept(FieldKinds.otp))
        #expect(r.shown == "JBSWY3DP" && r.kept == "JBSWY3DP")
    }

    @Test func theCursorKeepsItsPlaceFromTheEnd() {
        let field = UITextField()
        field.text = "+44 2x0"
        if let p = field.position(from: field.endOfDocument, offset: -1) { field.selectedTextRange = field.textRange(from: p, to: p) }
        SecretTextInput.show("+44 20", in: field)
        #expect(field.text == "+44 20")
        #expect(field.selectedTextRange.map { field.offset(from: $0.end, to: field.endOfDocument) } == 1)
    }
}
#endif
