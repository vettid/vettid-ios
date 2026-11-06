import Foundation
import Observation

/// What the shell observes of the relay key (part of ``VaultRepository``).
public protocol RelayNoticeRepository: AnyObject, Observable, Sendable {
    /// (VAULT-MESSAGING 0.84.0 §3.4, §10.2) The latest `vault.status` has `relay: "refused"`: the vault could not move to its
    /// new relay address and may not receive messages until its keys are replaced. The shell's lasting notice, gone when a
    /// later status has no `relay`. Default: false.
    var relayRefused: Bool { get }
}

public extension RelayNoticeRepository {
    var relayRefused: Bool { false }
}
