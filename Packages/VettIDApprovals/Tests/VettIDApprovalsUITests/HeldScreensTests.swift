#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDApprovals
@testable import VettIDApprovalsUI
@testable import VettIDData
@testable import VettIDUI

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The screens of an agent's request held for approval (ANDROID-PLAN 0.1.116 AA5): each kind rendered from the item list, its
/// row, and the answer before the screen closes. Mirrors vettid-android's `DeviceAsksScreenTest`.
@MainActor
@Suite(.serialized) struct HeldScreensTests {
    private let items = [ItemSummary(
        itemID: "i1", version: 1, name: "GitHub", category: "login", sensitivity: .secret,
        fieldLabels: [ItemFieldLabel(fieldID: "f1", label: "Token", kind: "password"), ItemFieldLabel(fieldID: "f2", label: "User", kind: "text")]
    )]

    private func request(_ h: HeldApproval) -> DeviceRequest {
        DeviceRequest(type: "approval.pending", id: "h1", deviceName: "Bot", role: "agent", requestType: "agent.request", receivedAt: Samples.t0, exp: Date().addingTimeInterval(300), deviceID: "A", held: h)
    }

    private func state(_ h: HeldApproval, loaded: Bool = true) -> ApprovalDetailState {
        var s = ApprovalDetailState(key: "device:approval.pending:h1")
        s.approval = .device(request(h))
        s.heldItems = items
        s.itemsLoaded = loaded
        return s
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private var all: [HeldApproval] {
        [
            .itemUse(itemID: "i1", fieldID: "f2", data: Array("hello".utf8)), .itemUse(itemID: "i1", fieldID: "f2", data: [0xFF, 0x00, 0x7F]),
            .itemGet(itemID: "i1", fieldIDs: ["f1", "f2"]), .itemGet(itemID: "i1", fieldIDs: nil), .catalog, .desktopStepUp, .unshown,
            .itemUse(itemID: "i9", fieldID: "f2", data: [1]),
        ]
    }

    @Test func everyHeldRequestRenders() {
        for h in all {
            let s = state(h)
            #expect(height(ApprovalDetailScreen(state: s, actions: DecisionActions())) > 0, "\(s)")
        }
        #expect(height(ApprovalDetailScreen(state: state(.catalog, loaded: false), actions: DecisionActions())) > 0)
    }

    @Test func theDataBoxShowsTheAgentsDataUnderItsLabel() {
        let text = HeldFacts(request: request(.catalog), show: .use(item: "GitHub", field: "User", data: .text("hello"), bytes: 5), now: Date())
        let hex = HeldFacts(request: request(.catalog), show: .use(item: "GitHub", field: "User", data: .hex("ff 00"), bytes: 2), now: Date())
        let catalog = HeldFacts(request: request(.catalog), show: .catalog, now: Date())
        #expect(height(text) > height(catalog) && height(hex) > height(text), "the hex adds its line")
    }

    @Test func aRevealSaysItsFieldsAndAlwaysTheHistoryLine() {
        let some = HeldFacts(request: request(.catalog), show: .get(item: "GitHub", fields: ["Token"]), now: Date())
        let all = HeldFacts(request: request(.catalog), show: .get(item: "GitHub", fields: nil), now: Date())
        #expect(height(some) > height(HeldFacts(request: request(.catalog), show: .catalog, now: Date())) && height(all) > 0)
    }

    @Test func theRowsComeFromTheItemList() {
        var list = ApprovalsState()
        list.items = items
        list.approvals = [.device(request(.itemGet(itemID: "i1", fieldIDs: ["f1"])))]
        #expect(list.heldShow(list.approvals[0]) == .get(item: "GitHub", fields: ["Token"]))
        #expect(list.heldShow(Samples.auth()) == nil && list.heldShow(Samples.device("device.session.pending")) == nil)
        list.itemsLoaded = false
        list.items = []
        #expect(list.heldShow(list.approvals[0]) == .noItem(use: false, loading: true))
        let row = ApprovalRow(approval: list.approvals[0], name: nil, held: list.heldShow(list.approvals[0]), onOpen: { _ in })
        #expect(height(row) > 0)
    }

    @Test func eachAnswerRenders() {
        for o in [DeviceOutcome.denied, .noLongerWaiting, .referred, .approved(result: "ok"), .approved(result: nil), .approved(result: "forbidden"), .approved(result: "x")] {
            var s = state(.catalog)
            s.outcome = o
            #expect(height(ApprovalDetailScreen(state: s, actions: DecisionActions())) > 0, "\(o)")
        }
    }

    /// Approve is not offered where the app cannot approve; Deny stays.
    @Test func approveIsOfferedOnlyWhereTheAppCanApprove() {
        #expect(state(.catalog).canApprove() && state(.itemGet(itemID: "i1", fieldIDs: ["f1"])).canApprove())
        #expect(!state(.unshown).canApprove() && !state(.desktopStepUp).canApprove() && !state(.itemUse(itemID: "i9", fieldID: "f1", data: [1])).canApprove())
        #expect(!state(.catalog, loaded: false).canApprove())
    }
}

// swiftlint:enable line_length
#endif
