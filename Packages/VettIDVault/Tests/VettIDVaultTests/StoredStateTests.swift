import Foundation
import Testing
@testable import VettIDVault
import VettIDRelay

// swiftlint:disable line_length
extension VaultDeviceTests {
    /// The shape of the device state as builds store it today, every field present. A later build must still decode it: a field
    /// added to the state, the vault record, the recovery record or an outbox entry is optional (or decoded with a default), or
    /// this test fails and every installed phone would stop reading its own state. Never edit this fixture to make it pass.
    static let storedStateToday = """
    {"role":"device","name":"phone","relayURL":"https://relay.example.invalid","vaultID":"v-1","deviceID":"d-1",
    "vault":{"ik":"aWs=","kem":"a2Vt","relayURL":"https://relay.example.invalid","mailbox":"mb-1","relayPk":"cGs=","token":"t","tokenExpMs":1790000000000,"sessions":"","suite":1,
    "awaiting":[{"createdMs":1790000000000,"state":"c3Q="}]},
    "seen":{"m1":1790000000000},"seenInner":{"i1":1790000000000},"issuedExpMs":1790000000000,"alt":"{}",
    "credential":{"blob":"YmxvYg==","version":3},
    "utks":[{"id":"u1","ek":"ZWs=","expiresAtMs":1790000000000}],
    "recovery":{"recoveryID":"r1","requestID":"q1","credentialBackup":true,"opens":[{"id":"o1","state":{"unanswered":{}}},{"id":"o2","state":{"refused":{"_0":"x"}}},{"id":"o3","state":{"ok":{}}}],
    "replaced":{"recoveryID":"r0","requestID":"q0"},"earlier":["r0"],"lostOk":false,"pairing":"c","invitation":"r2","invitationSent":false},
    "outbox":[{"id":"x1","type":"vault.status","relayURL":"https://relay.example.invalid","mailbox":"mb-1","token":"t","envelope":"ZQ==","attempts":1}],
    "signerSeen":true,"unsettled":{"i2":1790000000000},"transferUserGuid":"g","recoveryPairedCtx":"c"}
    """

    @Test func theStateStoredTodayStillDecodes() throws {
        let st = try JSONDecoder().decode(DeviceState.self, from: Data(Self.storedStateToday.utf8))
        #expect(st.deviceID == "d-1" && st.vault?.mailbox == "mb-1" && st.outbox.count == 1 && st.recovery?.opens?.count == 3)
        #expect(st.utks.count == 1 && st.signerSeen && st.unsettled?["i2"] == 1_790_000_000_000)
    }

    @Test func aStoredStateThatLoadsFromTheStore() throws {
        let store = InMemoryDeviceStateStore()
        store.save(Array(Self.storedStateToday.utf8))
        let d = try VaultDevice.load(config(store), secrets: try DeviceSecrets.generate())
        #expect(d != nil)
    }

    /// A state that does not decode is the phone's own state being unreadable, not a failed connection.
    @Test func aStoredStateThatDoesNotDecodeIsNamed() throws {
        let store = InMemoryDeviceStateStore()
        store.save(Array(#"{"role":"device"}"#.utf8))
        #expect(throws: StoredStateUnreadable.self) { try VaultDevice.load(self.config(store), secrets: try DeviceSecrets.generate()) }
    }
}
// swiftlint:enable line_length
