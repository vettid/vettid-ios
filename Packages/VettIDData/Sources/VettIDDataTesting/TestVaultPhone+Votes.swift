#if DEBUG
import Foundation
import VettIDData

extension TestVaultPhone {
    /// The public votes site a phone reads (none unless a test serves one), and the hourly wait it releases.
    static func votes(_ c: inout VaultManagerConfig, _ site: (any VoteSite)?, _ pauses: TestPauses) {
        c.votesSite = site
        c.votesSleep = { d in try await pauses.sleep(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) }
    }
}
#endif
