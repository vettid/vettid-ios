#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDConnections
@testable import VettIDConnectionsUI
import VettIDData
import VettIDUI

// Expected texts stay on one line each.
// swiftlint:disable line_length

/// Service connections on the connect screens, the Connections list and a connection's page (VAULT-MESSAGING §6.4
/// "Service connections", IOS-PLAN §4.13, ANDROID-PLAN §4 "Service connections (0.1.90)"; vettid-android #237's
/// "You are connected"). Mirrors vettid-android `ConnectFlowNamesTest`'s two service cases.
@MainActor
@Suite struct ServiceScreensTests {
    static func service(_ id: String = "s1", favorite: Bool = false) -> ConnectionInfo {
        var c = ConnectionInfo(id: id, name: "", state: .active)
        c.firstName = "Example"
        c.lastName = "Bank"
        c.isService = true
        c.favorite = favorite
        c.keyFingerprint = "0123 4567 89ab cdef 0123 4567 89ab cdef"
        c.asks = AskState()
        return c
    }

    /// The texts, word for word (ANDROID-PLAN's table; #237's approved texts).
    @Test func theTextsAreWordForWord() {
        #expect(ServiceTexts.label == "Service")
        #expect(ServiceTexts.sectionTitle == "Services")
        #expect(ServiceTexts.requestLine == "This is a service, not a person.")
        #expect(ServiceTexts.requestCaveat == "The invitation says so. VettID has not checked who runs it.")
        #expect(ServiceTexts.nameLabel == "Name given by the service")
        #expect(ServiceTexts.canAskTitle == "What this service can ask")
        #expect(ServiceTexts.canAskBody == "It can ask you to confirm a sign-in or approve an action. It can't message or call you, and it can't ask for your data.")
        #expect(ServiceTexts.canAskBodyVotes == "It can ask you to confirm a sign-in, approve an action or vote. It can't message or call you, and it can't ask for your data.")
        #expect(ServiceTexts.forbidden == "Services can't do that.")
        #expect(ConnectStrings.connectedBodyService("X") == "You're connected to X. It can ask you to sign in, vote and update your profile.")
        #expect(ConnectStrings.connectedBodyServiceUnnamed == "You're connected. The service can ask you to sign in, vote and update your profile.")
    }

    /// vettid-android #237: a service is connected without an offer to message it.
    @Test func aServiceIsConnectedWithoutAnOfferToMessageIt() {
        #expect(ConnectedScreen.body("VettID Member Service", service: true) == "You're connected to \u{2068}VettID Member Service\u{2069}. It can ask you to sign in, vote and update your profile.")
        #expect(ConnectedScreen.body(nil, service: true) == "You're connected. The service can ask you to sign in, vote and update your profile.")
        #expect(!ConnectedScreen.body("VettID Member Service", service: true).contains("message each other"))
        #expect(ConnectedScreen.buttons(hasMessages: true, service: true) == ["Done"])
        // A smoke check only: the screen renders.
        #expect(height(ConnectedScreen(name: "VettID Member Service", onMessage: {}, onDone: {}, service: true)) > 0)
    }

    @Test func aPersonIsStillOfferedAMessage() {
        #expect(ConnectedScreen.body("Sam Lee") == "You and \u{2068}Sam Lee\u{2069} can now message each other through your vaults.")
        #expect(ConnectedScreen.buttons(hasMessages: true, service: false) == ["Send a message", "Done"])
        #expect(ConnectedScreen.buttons(hasMessages: false, service: false) == ["Done"])
    }

    /// A request with the marker shows the name labelled "Name given by the service", the line and its small print above
    /// the code; one without shows none of them.
    @Test func theRequestOfAServiceSaysSo() {
        func state(_ service: Bool) -> AcceptState {
            var s = AcceptState()
            s.step = .compare
            s.sas = "042817"
            s.name = "Example Bank"
            s.service = service
            return s
        }
        func compare(_ service: Bool, size: DynamicTypeSize = .large) -> CGFloat {
            height(CompareContent(state: state(service), who: "Example Bank").environment(\.dynamicTypeSize, size))
        }
        let lines = height(ServiceRequestHeader(name: "Example Bank"))
        #expect(lines > 60)
        #expect(compare(true) >= compare(false) + lines - 1)
        // At the largest text size the lines are there in full.
        let big = height(ServiceRequestHeader(name: "Example Bank").environment(\.dynamicTypeSize, .accessibility5))
        #expect(big > lines && compare(true, size: .accessibility5) >= compare(false, size: .accessibility5) + big - 1)
        // A smoke check only: the whole screen renders.
        #expect(height(AcceptScreen(state: state(true), actions: AcceptActions())) > 0)
    }

    /// The Services section is there only with a service. Rendering the screens is a smoke check only.
    @Test func theServicesSectionIsThereOnlyWithAService() {
        var people = ConnectionsState()
        people.loading = false
        people.connections = [ConnectionsScreensTests.connection("p1")]
        var both = people
        both.services = [Self.service("s1", favorite: true), Self.service("s2")]
        #expect(ConnectionList.showsServices(both) && !ConnectionList.showsServices(people))
        var onlyServices = ConnectionsState()
        onlyServices.loading = false
        onlyServices.services = [Self.service()]
        #expect(!onlyServices.isEmpty && ConnectionList.showsServices(onlyServices))
        for s in [people, both, onlyServices] {
            #expect(height(ConnectionsScreen(state: s, chrome: chrome, actions: ConnectionsActions()), fit: false) > 0)
        }
    }

    /// A service's page: no message, no sharing cards, "What this service can ask" (with or without votes), and its
    /// names labelled as the service's; a person's page has all of them and no such card.
    @Test func aServicesPageHasNoPersonOnlyActions() {
        var actions = DetailActions()
        actions.onMessage = {}
        actions.onHistory = {}
        actions.onSharing = {}
        actions.onSharedWithYou = {}
        actions.onShareItems = {}
        actions.onOpenRule = { _ in }
        actions.onAskForSomething = {}
        let s = Self.service()
        var state = ConnectionDetailState(connectionID: s.id)
        state.connection = s
        state.loading = false
        let screen = ConnectionDetailScreen(state: state, actions: actions)
        #expect(screen.pill(s).map(\.label) == ["Add \u{2068}Example Bank\u{2069} to favourites", "History", "Remove"])
        #expect(!DetailContent.showsSharing(s, actions) && DetailContent.showsCanAsk(s))
        #expect(ProfileCard.accountNameLabel(s) == "Name given by the service")
        #expect(ServiceCanAskCard.body(votes: false) == ServiceTexts.canAskBody && ServiceCanAskCard.body(votes: true) == ServiceTexts.canAskBodyVotes)
        var person = s
        person.isService = false
        #expect(screen.pill(person).first?.label == "Message \u{2068}Example Bank\u{2069}")
        #expect(DetailContent.showsSharing(person, actions) && !DetailContent.showsCanAsk(person))
        #expect(ProfileCard.accountNameLabel(person) == "VettID account name")
        // The card has its title and body (the votes one at least as long), at every size.
        for size in [DynamicTypeSize.large, .accessibility5] {
            let plain = height(ServiceCanAskCard(votes: false).environment(\.dynamicTypeSize, size))
            #expect(plain > 60 && height(ServiceCanAskCard(votes: true).environment(\.dynamicTypeSize, size)) >= plain)
        }
        // Rendering the whole page is a smoke check only.
        #expect(height(ConnectionDetailScreen(state: state, actions: actions)) > 0)
    }

    /// The asks card leaves out the person's "can ask you for things" line for a service, whose own card says what it
    /// can ask; the paused and muted states are said as for a person.
    @Test func aServicesAsksCardHasNoPersonsLine() {
        let usual = AsksView.of(AskState())!
        #expect(AsksCard.showsUsualLine(usual, service: false) && !AsksCard.showsUsualLine(usual, service: true))
        let card = { (service: Bool) in
            AsksCard(view: usual, name: "Example", busy: false, service: service, onMute: { _ in }, onResume: {})
        }
        #expect(height(card(false)) > height(card(true)) + 20)
    }

    private var chrome: ShellChrome { ShellChrome(accountName: "Ada Lovelace", onMenu: {}, onAvatar: {}) }

    private func height(_ view: some View, fit: Bool = true) -> CGFloat {
        let size = fit ? CGSize(width: 390, height: 20_000) : CGSize(width: 390, height: 844)
        return UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: size).height
    }

}
// swiftlint:enable line_length
#endif
