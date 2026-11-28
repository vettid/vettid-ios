import Testing
@testable import VettIDData

/// A connection's title (VAULT-MESSAGING §10.8, §6.4 "Service connections"): a person's "First Last" only, a service's
/// "First Last" or else its own name, cleaned. Mirrors vettid-android `SocialModels.kt` `displayName`.
@Suite struct ConnectionTitleTests {
    static func connection(_ name: String, first: String? = nil, last: String? = nil, service: Bool) -> ConnectionInfo {
        var c = ConnectionInfo(id: "c1", name: name, state: .active)
        c.firstName = first
        c.lastName = last
        c.isService = service
        return c
    }

    @Test func aServiceWithoutFirstLastIsTitledByItsOwnNameCleaned() {
        let c = Self.connection(" Example\u{200B} Bank ", service: true)
        #expect(c.displayName == "Example Bank")
        #expect(c.secondaryName == nil, "its name is not repeated under itself")
        #expect(DesktopTargets.name(c) == "Example Bank", "the desktop rows follow the same rule")
    }

    @Test func aPersonsDisplayNameNeverStandsInForFirstLast() {
        let c = Self.connection("Countess", service: false)
        #expect(c.displayName.isEmpty)
        #expect(c.secondaryName == "Countess")
        #expect(DesktopTargets.name(c) == nil)
    }

    @Test func aServicesFirstLastWinsOverItsName() {
        let c = Self.connection("Bank Online", first: "Example", last: "Bank", service: true)
        #expect(c.displayName == "Example Bank")
        #expect(c.secondaryName == "Bank Online")
    }

    @Test func aServiceWithNothingVisibleHasNoTitle() {
        for name in ["", "  ", "\u{200B}\u{202E}"] {
            let c = Self.connection(name, service: true)
            #expect(c.displayName.isEmpty && DesktopTargets.name(c) == nil, "\(name.unicodeScalars.map(\.value))")
        }
    }
}
