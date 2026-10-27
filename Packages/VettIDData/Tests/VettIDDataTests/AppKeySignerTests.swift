import Foundation
import Testing
@testable import VettIDData
import VettIDKeys
import VettIDKeysTesting

/// The member API's signer uses the app key the store holds and never makes one: a request on its way after a wipe fails
/// instead of leaving a new key on a phone left as freshly installed.
@Suite struct AppKeySignerTests {
    @Test func noKeyIsMadeBySigning() throws {
        let store = SoftwareAppKeyStore()
        let signer = StoredAppKeySigner(store: store)
        #expect(throws: KeysError.missing("app key")) { try signer.sign([1, 2, 3]) }
        #expect(throws: KeysError.missing("app key")) { try signer.spki() }
        #expect(store.current == nil, "no key made")
    }

    @Test func theKeyTheStoreHoldsSigns() throws {
        let store = SoftwareAppKeyStore()
        let signer = StoredAppKeySigner(store: store)
        let first = try store.getOrCreate().spki()
        #expect(try signer.spki() == first)
        #expect(try !signer.sign([1, 2, 3]).isEmpty)
        // A new key for a new vault is used from the next request on.
        let second = try store.regenerate().spki()
        #expect(try signer.spki() == second && second != first)
    }

    @Test func aLockedIPhoneIsNotAMissingKey() throws {
        let store = SoftwareAppKeyStore()
        _ = try store.getOrCreate()
        store.source.behaviour = .locked
        #expect(throws: KeysError.unavailable("app key")) { try StoredAppKeySigner(store: store).sign([1]) }
    }
}
