#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDMessages
@testable import VettIDMessagesUI
import VettIDUI

/// A service's conversation (VAULT-MESSAGING §6.4) has no composer: "Services can't do that." in its place, also after a
/// refused send; a person's has the composer.
@MainActor
@Suite struct ServiceComposerTests {
    static func state(service: Bool, forbidden: Bool = false) -> ConversationState {
        var c = ConnectionInfo(id: "c1", name: "", state: .active)
        c.firstName = "Example"
        c.isService = service
        var s = ConversationState(connectionID: "c1")
        s.connection = c
        s.loading = false
        s.serviceForbidden = forbidden
        s.photosAvailable = true
        return s
    }

    @Test func aServiceHasTheTextInPlaceOfTheComposer() {
        #expect(Composer.note(Self.state(service: true), name: "Example") == "Services can't do that.")
        #expect(Composer.note(Self.state(service: false, forbidden: true), name: "Example") == "Services can't do that.")
        #expect(Composer.note(Self.state(service: false), name: "Example") == nil)
        var inactive = Self.state(service: false)
        inactive.connection?.state = .stale
        #expect(Composer.note(inactive, name: "Example") != nil && Composer.note(inactive, name: "Example") != ServiceTexts.forbidden)
    }
}
#endif
