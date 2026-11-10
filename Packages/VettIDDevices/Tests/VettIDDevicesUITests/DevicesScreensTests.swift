#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import VettIDData
import VettIDUI
@testable import VettIDDevices
@testable import VettIDDevicesUI

/// The Devices & agents list and a device's page (ANDROID-PLAN 0.1.53 AA1) rendered: every state, the page leaving once, the messages
/// told once, the remove text, and the pill. What the screens say is checked, as text, in `DeviceTextsTests` and `DeviceStringsTests`
/// (the hosted tree gives no text without an assistive technology). Mirrors vettid-android `DevicesScreenTest`.
@MainActor
@Suite(.serialized) struct DevicesScreensTests {
    private var chrome: ShellChrome { ShellChrome(accountName: "Ada Lovelace", onMenu: {}, onAvatar: {}) }
    private let now = Samples.now

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return window
    }

    private func list(_ s: DevicesState, _ actions: DevicesActions = DevicesActions()) -> DevicesScreen {
        DevicesScreen(state: s, chrome: chrome, now: now, calendar: Samples.calendar(), actions: actions)
    }

    private func page(_ s: DeviceState, _ actions: DevicePageActions = DevicePageActions()) -> DevicePageScreen {
        DevicePageScreen(state: s, actions: actions, now: now, calendar: Samples.calendar())
    }

    @Test func everyListStateRenders() {
        var loading = DevicesState()
        loading.load = .loading
        var failed = DevicesState()
        failed.error = .network
        failed.load = .failed
        let states = [
            loading, failed, Samples.list(Samples.phone), Samples.list(Samples.phone, Samples.agent, Samples.desktop),
            Samples.list(Samples.phone, Samples.agent) { $0.error = .ownerCheckRequired },
            Samples.list(Samples.phone, Samples.agent) { $0.removedDevice = Samples.desktop },
        ]
        for s in states { #expect(height(list(s)) > 0, "\(s)") }
    }

    @Test func everyPageStateRenders() {
        let ended = DeviceInfo(id: "a2", kind: "agent", name: "", ik: "not base64")
        let old = DeviceInfo(id: "app2", kind: "app", name: "Old phone", sessionExpiresAt: now.addingTimeInterval(600))
        let odd = DeviceInfo(id: "x", kind: "toaster", name: "VettID")
        var loading = DeviceState()
        loading.loaded = false
        var unreadable = DeviceState()
        unreadable.loadError = .network
        let states = [
            loading, unreadable, Samples.page(nil), Samples.page(Samples.agent), Samples.page(Samples.desktop), Samples.page(ended),
            Samples.page(old), Samples.page(odd), Samples.page(Samples.phone),
            Samples.page(Samples.agent) { $0.confirm = .endAccess },
            Samples.page(Samples.agent) { $0.confirm = .remove; $0.removalBoundSeconds = 960 },
            Samples.page(Samples.desktop) { $0.confirm = .remove },
            Samples.page(Samples.agent) { $0.failure = .endAccess; $0.error = .network },
            Samples.page(Samples.agent) { $0.failure = .remove; $0.error = .ownerCheckRequired },
            Samples.page(Samples.agent) { $0.busy = true; $0.accessEnded = true },
        ]
        for s in states { #expect(height(page(s)) > 0, "\(s)") }
    }

    /// One way out, however it came about: a single step back for a device no longer listed, this phone, and a removal; none for a
    /// page that shows its device or has not read the list yet.
    @Test func thePageLeavesOnceWhenThereIsNothingToShow() {
        func backs(_ s: DeviceState) -> Int {
            var n = 0
            var a = DevicePageActions()
            a.onBack = { n += 1 }
            _ = host(page(s, a))
            return n
        }
        #expect(backs(Samples.page(nil)) == 1)
        #expect(backs(Samples.page(Samples.phone)) == 1)
        #expect(backs(Samples.page(Samples.agent) { $0.removed = true }) == 1)
        // Removed here, its notice not yet shown: the page stays for it.
        #expect(backs(Samples.page(Samples.agent) { $0.removedDevice = Samples.agent }) == 0)
        #expect(backs(Samples.page(Samples.agent)) == 0)
        var unread = Samples.page(nil)
        unread.loaded = false
        #expect(backs(unread) == 0)
    }

    @Test func theRemovedAndAccessEndedMessagesAreToldOnce() {
        var removedShown = 0
        var actions = DevicesActions()
        actions.onRemovedShown = { removedShown += 1 }
        _ = host(list(Samples.list(Samples.phone, Samples.agent) { $0.removedDevice = Samples.desktop }, actions))
        #expect(removedShown == 1)
        _ = host(list(Samples.list(Samples.phone, Samples.agent), actions))
        #expect(removedShown == 1)
        var endedShown = 0
        var page = DevicePageActions()
        page.onAccessEndedShown = { endedShown += 1 }
        _ = host(self.page(Samples.page(Samples.agent) { $0.accessEnded = true }, page))
        #expect(endedShown == 1)
        _ = host(self.page(Samples.page(Samples.agent), page))
        #expect(endedShown == 1)
        var removedOnPage = 0
        page.onRemovedShown = { removedOnPage += 1 }
        _ = host(self.page(Samples.page(Samples.agent) { $0.removedDevice = Samples.agent }, page))
        #expect(removedOnPage == 1)
        _ = host(self.page(Samples.page(Samples.agent), page))
        #expect(removedOnPage == 1)
    }

    /// The remove confirmation of an agent says how long a service may still accept its permissions only while it has one; a
    /// desktop's has its own text (Android's `removingAnAgent…`, `withNoPermissionLeft…` and `removingADesktop…`).
    @Test func theRemoveTextSaysTheBoundOnlyWhileTheAgentHasAPermission() {
        let withBound = DevicePageScreen.removeText(agent: true, boundSeconds: 960)
        #expect(withBound.contains("Services it showed a permission to may accept it for up to 16 minutes."))
        #expect(withBound.contains("To use this agent again, pair it again."))
        #expect(withBound.contains("Its permissions and its share rules are deleted."))
        #expect(DevicePageScreen.removeText(agent: true, boundSeconds: 3_660).contains("up to 61 minutes."))
        let none = DevicePageScreen.removeText(agent: true, boundSeconds: 0)
        #expect(!none.contains("Services it showed") && none.contains("Its permissions and its share rules are deleted."))
        #expect(DevicePageScreen.removeText(agent: false, boundSeconds: 960)
            == "It loses access to your vault at once and cannot connect again. To use it again, pair it again.")
    }

    /// **History** carries the device's own name (raw, as it gave it) and is absent for a device with no name; **Remove** only for a
    /// device with actions.
    @Test func theHistoryActionCarriesTheNameAndRemoveIsForActionableDevicesOnly() {
        var query: String?
        var removed = 0
        var actions = DevicePageActions()
        actions.onHistory = { query = $0 }
        actions.onRemove = { removed += 1 }
        let agent = DevicePageScreen.pillActions(Samples.agent, actions)
        #expect(agent.map(\.label) == ["History", "Remove"] && agent[1].destructive)
        agent[0].action()
        #expect(query == "Claude")
        agent[1].action()
        #expect(removed == 1)
        #expect(DevicePageScreen.pillActions(DeviceInfo(id: "a", kind: "agent", name: ""), actions).map(\.label) == ["Remove"])
        let app = DeviceInfo(id: "app2", kind: "app", name: "Old phone")
        #expect(DevicePageScreen.pillActions(app, actions).map(\.label) == ["History"])
        // A name that needs cleaning is searched as the device gave it; the search cuts it as it cuts every search.
        let raw = DeviceInfo(id: "a", kind: "agent", name: "Re\u{202E}d")
        DevicePageScreen.pillActions(raw, actions)[0].action()
        #expect(query == "Re\u{202E}d")
    }

    /// A row wraps at the largest text size instead of being cut, and stays inside the screen.
    @Test func aRowWrapsAtTheLargestSize() {
        func size(_ type: DynamicTypeSize) -> CGSize {
            let row = DeviceRow(device: Samples.agent, now: now, calendar: Samples.calendar()) {}
            let root = row.environment(\.dynamicTypeSize, type).vettIDTheme(.light)
            return UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: 390, height: 20_000))
        }
        #expect(size(.accessibility5).height > size(.large).height && size(.accessibility5).width <= 390)
    }
}
#endif
