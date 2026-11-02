#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDApprovals
@testable import VettIDApprovalsUI
@testable import VettIDData
import VettIDUI

/// Requests from a service (VAULT-MESSAGING §6.4 "Service connections", IOS-PLAN §4.13): the label "Service" beside the
/// name of a sign-in or approval it asks for, in its row and on its screen; its connection request with "This is a
/// service, not a person." and its small print, and the name labelled "Name given by the service". A request without the
/// marker shows nothing new.
@MainActor
@Suite struct ServiceApprovalsTests {
    static func service(_ id: String = "c1") -> ConnectionInfo {
        var c = Samples.connection(id, first: "Example")
        c.isService = true
        return c
    }

    static func outgoing(service: Bool) -> OutgoingRequest {
        var r = OutgoingRequest(
            connectionID: "o1", sas: "042817", remote: true, name: "Example Bank", state: .pending, receivedAt: Samples.t0, exp: nil
        )
        r.isService = service
        return r
    }

    /// The view's ideal width (unconstrained).
    private func width(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.fixedSize().vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 10_000, height: 4_000)).width
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 4_000)).height
    }

    @Test func aServicesConnectionRequestSaysSo() {
        let service = Self.outgoing(service: true), person = Self.outgoing(service: false)
        #expect(Facts.outgoingNameLabel(service) == "Name given by the service")
        #expect(Facts.outgoingNameLabel(person) == "Invitation from")
        let lines = height(ServiceRequestLines())
        let withLines = height(Facts(approval: .connection(.outgoing(service)), name: nil))
        let without = height(Facts(approval: .connection(.outgoing(person)), name: nil))
        #expect(lines > 30 && withLines >= without + lines)
    }

    /// Which rows carry the label: a request whose connection is a service, an outgoing request whose invitation said so;
    /// never one of a person or of a connection not in the list.
    @Test func theRowsOfAServiceAreLabelled() {
        var s = ApprovalsState()
        s.connections = ["c1": Self.service(), "c2": Samples.connection("c2")]
        #expect(s.isService(Samples.auth("a1", conn: "c1", purpose: .signin)))
        #expect(s.isService(Samples.critical("k1", conn: "c1")))
        #expect(!s.isService(Samples.auth("a2", conn: "c2")) && !s.isService(Samples.auth("a3", conn: "gone")))
        #expect(s.isService(.connection(.outgoing(Self.outgoing(service: true)))))
        #expect(!s.isService(.connection(.outgoing(Self.outgoing(service: false)))) && !s.isService(.connection(Samples.incoming())))
        // The row puts the label on its title line: wider at its ideal size than the same row without it.
        let row = { (service: Bool) in
            ApprovalRow(approval: Samples.auth(), name: "Example Bank", service: service, onOpen: { _ in })
        }
        #expect(width(row(true)) > width(row(false)) + 20)
    }

    /// On the decision screen the label sits beside the "From" name; with a match code (no "From" line) over the title.
    @Test func theDecisionNamesTheService() {
        var state = ApprovalDetailState(key: "auth:a1")
        state.connectionIsService = true
        state.connectionName = "Example Bank"
        let signin = Samples.auth("a1", purpose: .signin)
        let coded = Samples.auth("a2", purpose: .signin, matchCode: "42")
        #expect(!ApprovalDetailScreen.labelsTitle(signin, state) && ApprovalDetailScreen.labelsTitle(coded, state))
        state.connectionIsService = false
        #expect(!ApprovalDetailScreen.labelsTitle(coded, state))
        // The label over the title is read with it, once.
        state.connectionIsService = true
        state.approval = coded
        let title = ApprovalTexts.title(coded, name: "Example Bank")
        #expect(ApprovalDetailScreen.titleSpoken(coded, state) == "\(title), Service")
        #expect(ApprovalDetailScreen.titleSpoken(signin, state) == nil)
        // Beside the "From" name: wider than the name alone.
        #expect(width(FromValue(text: "Example Bank", service: true)) > width(FromValue(text: "Example Bank", service: false)) + 20)
        // Rendering the screens is a smoke check only.
        for a in [signin, coded, Samples.auth("a3", purpose: .approval), Samples.critical()] {
            for service in [false, true] {
                state.approval = a
                state.connectionIsService = service
                #expect(height(ApprovalDetailScreen(state: state, actions: DecisionActions())) > 0)
            }
        }
    }
}
#endif
