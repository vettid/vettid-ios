#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import VettIDUI

/// The first of several secret fields: Return is "Next" and gives the keyboard to the field below; the last one submits.
/// Mirrors vettid-android's `ImeAction.Next`.
@MainActor
@Suite(.serialized) struct NextFieldTests {
    @Test func nextGivesTheKeyboardToTheFieldBelow() async throws {
        let submitted = Box()
        let form = Form(submitted: submitted)
        let window = host(form)
        defer { window.isHidden = true }
        let fields = textFields(in: window).sorted { $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY }
        try #require(fields.count == 3)
        #expect(fields.map(\.returnKeyType) == [.next, .next, .default])
        fields[0].becomeFirstResponder()
        #expect(fields[0].delegate?.textFieldShouldReturn?(fields[0]) == true)
        #expect(await eventually { fields[1].isFirstResponder })
        #expect(fields[1].delegate?.textFieldShouldReturn?(fields[1]) == true)
        #expect(await eventually { fields[2].isFirstResponder })
        #expect(!submitted.value && !form.wrongSubmit.value, "a field with Next never submits")
        _ = fields[2].delegate?.textFieldShouldReturn?(fields[2])
        #expect(submitted.value)
    }

    /// The last field of a form with "Next" (nothing below it in the form) closes the keyboard; a field below the form, out
    /// of it, is not given the keyboard.
    @Test func nextWithNothingBelowClosesTheKeyboard() async throws {
        let window = host(Lone())
        defer { window.isHidden = true }
        let fields = textFields(in: window).sorted { $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY }
        try #require(fields.count == 2)
        let field = fields[0]
        field.becomeFirstResponder()
        #expect(await eventually { field.isFirstResponder })
        _ = field.delegate?.textFieldShouldReturn?(field)
        #expect(await eventually { !field.isFirstResponder })
        #expect(!fields[1].isFirstResponder)
    }

    // MARK: - Helpers

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func textFields(in view: UIView) -> [UITextField] {
        ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(5))
        while clock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class Box {
    var value = false
}

private struct Form: View {
    let submitted: Box
    let wrongSubmit = Box()
    @State private var a = ""
    @State private var b = ""
    @State private var c = ""

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                SecretField("Current password", text: $a, next: true) { wrongSubmit.value = true }
                SecretField("New password", text: $b, next: true)
                SecretField("Confirm", text: $c) { submitted.value = true }
            }
        }
    }
}

private struct Lone: View {
    @State private var a = ""
    @State private var b = ""

    var body: some View {
        VStack {
            ScrollView { SecretField("Password", text: $a, next: true) }
            SecretField("Outside the form", text: $b)
        }
    }
}
#endif
