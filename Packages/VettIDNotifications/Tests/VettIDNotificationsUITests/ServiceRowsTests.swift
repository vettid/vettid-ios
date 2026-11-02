#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
@testable import VettIDNotificationsUI
import VettIDUI

/// A notification that names a service connection carries the label "Service" on the line that names it (VAULT-MESSAGING
/// §6.4, IOS-PLAN §4.13): the title when the title is the name, the second line when that one names it ("A new vote" with
/// "<service>: <vote>" under it); never on a line that does not.
@MainActor
@Suite struct ServiceRowsTests {
    static let names: FeedNames = {
        var bank = ConnectionInfo(id: "c1", name: "", state: .active)
        bank.firstName = "Example"
        bank.lastName = "Bank"
        bank.isService = true
        var sam = ConnectionInfo(id: "c2", name: "", state: .active)
        sam.firstName = "Sam"
        return FeedNames(connections: ["c1": bank, "c2": sam])
    }()

    @Test func theLabelGoesOnTheLineThatNamesTheService() {
        let message = NotificationsScreensTests.item("a", "message.received", connection: "c1")
        #expect(FeedKinds.title(message, Self.names).contains("Example Bank"))
        #expect(FeedRow.serviceLabel(message, Self.names) == .title)
        let vote = NotificationsScreensTests.item("v", "vote.open", connection: "c1", ref: "p1")
        #expect(!FeedKinds.title(vote, Self.names).contains("Example Bank"))
        #expect(FeedKinds.supporting(vote, Self.names)?.contains("Example Bank") == true)
        #expect(FeedRow.serviceLabel(vote, Self.names) == .supporting)
    }

    @Test func noLabelForAPersonOrWithoutAConnection() {
        #expect(FeedRow.serviceLabel(NotificationsScreensTests.item("b", connection: "c2"), Self.names) == .none)
        #expect(FeedRow.serviceLabel(NotificationsScreensTests.item("c", connection: "gone"), Self.names) == .none)
        #expect(FeedRow.serviceLabel(NotificationsScreensTests.item("d", "device.paired"), Self.names) == .none)
    }
}
#endif
