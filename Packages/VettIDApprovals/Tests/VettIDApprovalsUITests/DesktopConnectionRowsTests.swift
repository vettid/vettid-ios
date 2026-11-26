#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import VettIDApprovals
@testable import VettIDApprovalsUI
@testable import VettIDData
@testable import VettIDUI

// Texts and fixtures stay on one line each.
// swiftlint:disable line_length

/// ANDROID-PLAN 0.1.145 and 0.1.146 §4 "Requests held for approval": a desktop's held block or removal of a connection, in the
/// owner-approved words, with Approve and Deny; the deny-only desktop row for anything unresolved. Mirrors vettid-android
/// `DesktopConnectionRowsTest`.
@MainActor
@Suite(.serialized) struct DesktopConnectionRowsTests {
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    private func iso(_ s: String) -> String { AccountNames.isolate(s) }

    private func request(_ h: HeldApproval, name: String? = "Work desktop") -> DeviceRequest {
        DeviceRequest(type: "approval.pending", id: "h1", deviceName: name, role: "desktop", requestType: "block.add", receivedAt: Date(), exp: Date().addingTimeInterval(300), deviceID: "D", held: h)
    }

    private func block(_ id: String = "c1", note: String? = nil) -> HeldApproval { .desktopConnection(DesktopConnection(remove: false, connectionID: id, note: note)) }
    private func remove(_ id: String = "c1") -> HeldApproval { .desktopConnection(DesktopConnection(remove: true, connectionID: id)) }

    private func person(_ id: String, _ first: String, _ last: String, at: Date? = nil, service: Bool = false, state: ConnectionState = .active) -> ConnectionInfo {
        var c = ConnectionInfo(id: id, name: "", state: state)
        (c.firstName, c.lastName, c.createdAt, c.isService) = (first, last, at, service)
        return c
    }

    private func state(_ h: HeldApproval, _ cs: [ConnectionInfo], itemsRead: ItemsRead = .read) -> ApprovalDetailState {
        var s = ApprovalDetailState(key: "device:approval.pending:h1")
        s.approval = .device(request(h))
        s.heldConnections = cs
        s.itemsRead = itemsRead
        return s
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    @Test func theOwnerApprovedWordsWordForWord() {
        let a = PendingApproval.device(request(block()))
        let who = iso("Work desktop"), ana = iso("Ana Lee")
        let blocking = HeldShow.desktopConnection(remove: false, target: DesktopTargets.Shown(name: "Ana Lee", service: false), note: nil)
        let removing = HeldShow.desktopConnection(remove: true, target: DesktopTargets.Shown(name: "Ana Lee", service: false), note: nil)
        #expect(ApprovalTexts.title(a, held: blocking) == "\(who) wants to block \(ana)")
        #expect(ApprovalTexts.body(a, name: nil, held: blocking) == "Blocking ends your connection with \(ana). They can't connect with you again until you unblock them.")
        #expect(ApprovalTexts.title(a, held: removing) == "\(who) wants to remove \(ana)")
        #expect(ApprovalTexts.body(a, name: nil, held: removing) == "Removing ends your connection with \(ana).")
        #expect(ApprovalTexts.desktopNoteLabel(request(block())) == "Note from \(who):", "the desktop's name isolated")
        #expect(ApprovalTexts.desktopNoteLabel(request(block(), name: "\u{202E}Evil")) == "Note from \(iso("Evil")):")
    }

    @Test func aNamesakeIsFollowedByTheDayItWasConnected() {
        let a = PendingApproval.device(request(block()))
        let utc = TimeZone(identifier: "UTC")!
        let t = DesktopTargets.Shown(name: "Ana Lee", service: false, connectedOn: day)
        let date = day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: utc))
        #expect(ApprovalTexts.desktopTarget(t, zone: utc) == "\(iso("Ana Lee")) (connected \(date))")
        #expect(date.contains("2026"), "with its year")
        let shown = HeldShow.desktopConnection(remove: true, target: t, note: nil)
        let named = ApprovalTexts.desktopTarget(t)
        #expect(ApprovalTexts.title(a, held: shown) == "\(iso("Work desktop")) wants to remove \(named)")
        #expect(ApprovalTexts.body(a, name: nil, held: shown) == "Removing ends your connection with \(named).")
        #expect(ApprovalTexts.desktopTarget(DesktopTargets.Shown(name: "Ana Lee", service: false)) == iso("Ana Lee"), "unique: no date")
    }

    @Test func aResolvedBlockOrRemovalOffersApproveAndAnUnresolvedOneOnlyDeny() {
        let cs = [person("c1", "Ana", "Lee")]
        #expect(state(block(note: "spam"), cs).heldShow == .desktopConnection(remove: false, target: DesktopTargets.Shown(name: "Ana Lee", service: false), note: "spam"))
        #expect(state(block(), cs).canApprove() && state(remove(), cs).canApprove())
        #expect(state(block(), cs, itemsRead: .reading).canApprove() && state(block(), cs, itemsRead: .failed).canApprove(), "it names no item")
        for (name, s) in [("not listed", state(block("c9"), cs)), ("blocked", state(block(), [person("c1", "Ana", "Lee", state: .blocked)])), ("same day", state(block(), [person("c1", "Ana", "Lee", at: day), person("c2", "Ana", "Lee", at: day)])), ("no list", state(remove(), []))] {
            #expect(s.heldShow == .desktop && !s.canApprove(), Comment(rawValue: name))
        }
        #expect(!state(.desktopStepUp, cs).canApprove())
    }

    @Test func theNoteIsCleanedAndAnEmptyOneShowsNoBox() {
        let cs = [person("c1", "Ana", "Lee")]
        #expect(state(block(note: "\u{202E}spam\nline two\u{200B}"), cs).heldShow == .desktopConnection(remove: false, target: DesktopTargets.Shown(name: "Ana Lee", service: false), note: "spam\nline two"), "cleaned, lines kept")
        #expect(state(block(note: " \u{200B} "), cs).heldShow == .desktopConnection(remove: false, target: DesktopTargets.Shown(name: "Ana Lee", service: false), note: nil))
        let r = request(block())
        let target = DesktopTargets.Shown(name: "Ana Lee", service: false)
        let none = HeldFacts(request: r, show: .desktopConnection(remove: false, target: target, note: nil), now: Date())
        let one = HeldFacts(request: r, show: .desktopConnection(remove: false, target: target, note: "spam"), now: Date())
        let two = HeldFacts(request: r, show: .desktopConnection(remove: false, target: target, note: "spam\nagain"), now: Date())
        #expect(height(one) > height(none) && height(two) > height(one), "the label and box only with a note; its lines kept")
    }

    @Test func aServiceCarriesItsLabelBesideItsName() {
        let r = request(remove())
        let person = HeldFacts(request: r, show: .desktopConnection(remove: true, target: DesktopTargets.Shown(name: "Acme Bank", service: false), note: nil), now: Date())
        let service = HeldFacts(request: r, show: .desktopConnection(remove: true, target: DesktopTargets.Shown(name: "Acme Bank", service: true), note: nil), now: Date())
        #expect(height(service) > height(person), "the service line under the title")
        #expect(state(remove(), [self.person("c1", "Acme", "Bank", service: true)]).heldShow == .desktopConnection(remove: true, target: DesktopTargets.Shown(name: "Acme Bank", service: true), note: nil))
    }

    @Test func theScreenTheRowAndEachAnswerRender() {
        let cs = [person("c1", "Ana", "Lee"), person("c2", "Acme", "Bank", service: true)]
        for h in [block(note: "spam"), remove(), block("c2"), remove("c9"), HeldApproval.desktopStepUp] {
            #expect(height(ApprovalDetailScreen(state: state(h, cs), actions: DecisionActions())) > 0)
        }
        for o in [DeviceOutcome.approved(result: "ok"), .approved(result: "not_found"), .approved(result: "exists"), .approved(result: "limit"), .approved(result: "bad_request"), .noLongerWaiting, .denied] {
            var s = state(block(), cs)
            s.outcome = o
            #expect(height(ApprovalDetailScreen(state: s, actions: DecisionActions())) > 0, "\(o)")
        }
        var list = ApprovalsState()
        list.connections = Dictionary(uniqueKeysWithValues: cs.map { ($0.id, $0) })
        list.connectionList = cs
        list.approvals = [.device(request(remove("c2")))]
        let shown = list.heldShow(list.approvals[0])
        #expect(shown == .desktopConnection(remove: true, target: DesktopTargets.Shown(name: "Acme Bank", service: true), note: nil))
        let row = ApprovalRow(approval: list.approvals[0], name: nil, held: shown, onOpen: { _ in })
        let plain = ApprovalRow(approval: list.approvals[0], name: nil, held: .desktop, onOpen: { _ in })
        #expect(height(row) > height(plain), "a service's row carries its line")
    }

    @Test func aServicesNamesakeDateComesBeforeItsLabel() {
        let utc = TimeZone(identifier: "UTC")!
        let t = DesktopTargets.Shown(name: "Acme Bank", service: true, connectedOn: day)
        let date = day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: utc))
        // The line is the name with its date, then the label (``DesktopServiceLine``).
        #expect(ApprovalTexts.desktopTarget(t, zone: utc) == "\(iso("Acme Bank")) (connected \(date))")
        let cs = [person("c1", "Acme", "Bank", at: day, service: true), person("c2", "Acme", "Bank", at: day.addingTimeInterval(-86_400 * 40))]
        #expect(state(remove(), cs).heldShow == .desktopConnection(remove: true, target: t, note: nil))
    }

    @Test func eachRowOnAStaleAndAServiceConnection() {
        for c in [person("c1", "Ana", "Lee", state: .stale), person("c1", "Acme", "Bank", service: true)] {
            for h in [block(note: "n"), remove()] {
                #expect(state(h, [c]).canApprove(), "\(c.state) \(c.isService)")
            }
        }
    }

    @Test func theListAndTheScreenReadTheSameConnectionList() {
        // A malformed list with the same id twice: the row names it as the screen does.
        let cs = [person("c1", "Ana", "Lee", state: .blocked), person("c1", "Ana", "Lee")]
        var list = ApprovalsState()
        list.connections = Dictionary(cs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        list.connectionList = cs
        list.approvals = [.device(request(block()))]
        #expect(list.heldShow(list.approvals[0]) == state(block(), cs).heldShow)
    }

    @Test func theAnswersReadAsTheVaultsOwn() {
        let who = iso("Work desktop")
        for r in ["not_found", "exists", "limit", "bad_request"] {
            #expect(ApprovalTexts.outcome(.approved(result: r), who: who) == "Approved, but your vault answered: \(iso(r)).", Comment(rawValue: r))
        }
        #expect(ApprovalTexts.outcome(.noLongerWaiting, who: who) == "This request is no longer waiting.")
    }
}
// swiftlint:enable line_length
#endif
