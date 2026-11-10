import Foundation
import VettIDCrypto
import VettIDVault

/// TEST ONLY. The events of the member's other devices that change the Devices & agents list (§10.1, §10.3, §10.11).
extension FakeVaultService {
    /// `sync.event{kind}` (`device.paired`, `device.unlinked`, `device.session`, `leash.agent.suspended`): this phone gets it.
    public func deviceEventArrives(kind: String, deviceID: String? = nil) throws {
        try locked {
            let body = JsonBuilder().string("kind", kind)
            if let deviceID { body.string("device_id", deviceID) }
            try reply("sync.event", body.build())
        }
    }
}
