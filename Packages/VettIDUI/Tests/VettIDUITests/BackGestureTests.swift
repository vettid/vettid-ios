#if os(iOS)
import Testing
import UIKit
@testable import VettIDUI

/// The back gestures' block (``View/blocksBackGesture(_:)``): held per owner, so that one owner going (a step replacing
/// the screen's content, its old probe leaving after the new one arrived) never clears a block another one holds.
@MainActor
@Suite struct BackGestureTests {
    @Test func aBlockHoldsUntilEveryOwnerReleasesIt() throws {
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(UIViewController(), animated: false)
        let pop = try #require(nav.interactivePopGestureRecognizer)
        let d = try #require(PopGestureDelegate.of(nav))
        #expect(PopGestureDelegate.of(nav) === d && pop.delegate === d)
        #expect(d.gestureRecognizerShouldBegin(pop))
        let form = NSObject(), passwordStep = NSObject()
        d.block(true, by: form)
        d.block(true, by: passwordStep)
        #expect(!d.gestureRecognizerShouldBegin(pop))
        // The form's probe goes after the password step's arrived: the step's block stays.
        d.block(false, by: form)
        #expect(d.blocked && !d.gestureRecognizerShouldBegin(pop))
        d.block(false, by: passwordStep)
        #expect(!d.blocked && d.gestureRecognizerShouldBegin(pop))
        // Never from the root.
        nav.popViewController(animated: false)
        #expect(!d.gestureRecognizerShouldBegin(pop))
    }
}
#endif
