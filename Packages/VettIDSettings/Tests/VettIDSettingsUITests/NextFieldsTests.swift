#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDSettings
@testable import VettIDSettingsUI
import VettIDUI

/// Return on the first fields of a form moves on to the next one (I4 audit, accessibility; vettid-android's
/// `ImeAction.Next`): the current and new passwords of the password change and the new credential. (The first name's
/// "Next" is SwiftUI's `onSubmit`, which a hosted test cannot press.)
@MainActor
@Suite(.serialized) struct NextFieldsTests {
    @Test func thePasswordFieldsGoOnToTheNext() {
        let screens = [
            AnyView(ChangePasswordContent(state: ChangePasswordState())), AnyView(NewCredentialContent(state: NewCredentialState())),
        ]
        for view in screens {
            let window = host(view)
            defer { window.isHidden = true }
            #expect(fields(in: window).map(\.returnKeyType) == [.next, .next, .default])
        }
    }

    // MARK: - Helpers

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    /// The text fields of [window], top to bottom.
    private func fields(in window: UIWindow) -> [UITextField] {
        func all(_ v: UIView) -> [UITextField] { ((v as? UITextField).map { [$0] } ?? []) + v.subviews.flatMap(all) }
        return all(window).sorted { $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY }
    }
}
#endif
