#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
@testable import VettIDNotificationsUI
import VettIDUI

/// A notification naming a service connection carries the label "Service" beside its title (VAULT-MESSAGING §6.4,
/// IOS-PLAN §4.13); the name is as always.
@MainActor
@Suite struct ServiceRowsTests {
    @Test func aRowNamingAServiceIsLabelled() {
        var bank = ConnectionInfo(id: "c1", name: "", state: .active)
        bank.firstName = "Example"
        bank.lastName = "Bank"
        bank.isService = true
        var sam = ConnectionInfo(id: "c2", name: "", state: .active)
        sam.firstName = "Sam"
        let names = FeedNames(connections: ["c1": bank, "c2": sam])
        let fromBank = NotificationsScreensTests.item("a", "connection.authenticate.request", connection: "c1")
        #expect(FeedRow.namesService(fromBank, names))
        #expect(!FeedRow.namesService(NotificationsScreensTests.item("b", connection: "c2"), names))
        #expect(!FeedRow.namesService(NotificationsScreensTests.item("c", connection: "gone"), names))
        #expect(!FeedRow.namesService(NotificationsScreensTests.item("d", "device.paired"), names))
        for size in [DynamicTypeSize.large, .accessibility5] {
            let row = FeedRow(
                item: fromBank, names: names, archived: false, attention: false, unread: true, actions: NotificationsActions()
            )
            .environment(\.dynamicTypeSize, size)
            #expect(UIHostingController(rootView: row.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 2_000)).height > 0)
        }
    }
}
#endif
