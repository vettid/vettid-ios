#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDDataTesting
import VettIDOnboarding
@testable import VettIDOnboardingUI
import VettIDUI

/// (ANDROID-PLAN 0.1.124 §4 "The owner check's progress") The flow's wiring: it tells whether its check is out, with the
/// answer's message, and closes after the "Check passed" tick is held.
@MainActor
@Suite(.serialized) struct OwnerCheckFlowTests {
    let vault = FakeVaultRepository(.unlocked)

    init() {
        vault.ownerCheck = OwnerCheckView(state: .ok, deadline: Date().addingTimeInterval(3_600))
    }

    final class Told {
        var out: [(Bool, OwnerCheckMessage?)] = []
        var done = 0
    }

    private func host(_ vm: OwnerCheckViewModel, _ told: Told) -> UIWindow {
        let flow = OwnerCheckFlow(
            mode: .voluntary, repo: vault, vault: vault, model: vm, onDone: { told.done += 1 },
            onOut: { told.out.append(($0, $1)) }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: flow.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func eventually(within: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: within)
        while clock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func model() async -> OwnerCheckViewModel {
        OwnerCheckViewModel(repo: vault, vault: vault, tick: {})
    }

    @Test func aFailedCheckIsToldOutThenBackWithItsMessage() async {
        vault.checkResults = [.badPin(checksLeft: 8)]
        let gate = TestDeferred<Void>()
        vault.onCheck = { try? await gate.value() }
        let vm = await model()
        let told = Told()
        let window = host(vm, told)
        defer { window.isHidden = true }
        #expect(await eventually { vm.onOut != nil }, "wired on appear")
        vm.setPin("975310")
        vm.setPassword("pw")
        vm.submit()
        #expect(told.out.count == 1 && told.out[0].0 && told.out[0].1 == nil)
        gate.complete(())
        #expect(await eventually { told.out.count == 2 })
        #expect(told.out.last?.0 == false && told.out.last?.1 == .badPin(checksLeft: 8))
        #expect(told.done == 0)
    }

    @Test func aPassClosesAfterTheTick() async {
        let vm = await model()
        let told = Told()
        let window = host(vm, told)
        defer { window.isHidden = true }
        #expect(await eventually { vm.onOut != nil })
        vm.setPin("975310")
        vm.setPassword("pw")
        vm.submit()
        #expect(await eventually { vm.state.passedTick })
        #expect(told.done == 0, "the tick is held first")
        #expect(await eventually(within: .seconds(3)) { told.done == 1 }, "then the screen closes")
        #expect(told.out.last?.0 == false, "no longer out once closed")
    }
}
#endif
