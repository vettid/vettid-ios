import Foundation
import VettIDCrypto
import VettIDData

/// Invitations and requests for the view-model tests.
enum Samples {
    static let inviteID = "01JINVITE0000000000000000A"

    /// A real invitation link (VAULT-MESSAGING §6.4) of [kind] expiring at [exp].
    static func link(_ kind: InviteKind = .connection, exp: Date = Date().addingTimeInterval(600)) -> String {
        // The test payload's fields are fixed and valid: its link always encodes.
        try! InviteQr( // swiftlint:disable:this force_try
            kind: kind, relay: "https://relay.vettid.test", claimID: "abcdefghijklmnopqrstuvwxyz",
            hash: [UInt8](repeating: 1, count: 32), key: [UInt8](repeating: 2, count: 32), exp: UInt64(exp.timeIntervalSince1970)
        ).link()
    }

    static func incoming(
        _ pendingID: String = "pend-1", invite: String? = inviteID, state: RequestState = .pending, name: String? = "Ada Lovelace",
        remote: Bool = false
    ) -> PendingConnection {
        var r = ConnectionRequest(pendingID: pendingID, sas: "042817", remote: remote, name: name, receivedAt: Date(), exp: nil)
        r.inviteID = invite
        r.state = state
        return .incoming(r)
    }

    static func outgoing(
        _ connectionID: String = "conn-new", sas: String? = "042817", state: RequestState = .pending, remote: Bool = false
    ) -> PendingConnection {
        .outgoing(OutgoingRequest(
            connectionID: connectionID, sas: sas, remote: remote, name: "Inviter", state: state, receivedAt: Date(), exp: nil
        ))
    }

    static func active(_ id: String, first: String? = "Ada", last: String? = "Lovelace") -> ConnectionInfo {
        var c = ConnectionInfo(id: id, name: "", state: .active)
        c.firstName = first
        c.lastName = last
        return c
    }
}

/// Waits (up to 20 s, wall-clock) until [condition] holds; false when it never did. A view model follows a repository on
/// a later turn of the main actor (`onChange` runs before the change), so a test that changes a fake waits for what must
/// follow instead of checking right after `settle()`. Only a failing test waits the whole time.
@MainActor
func until(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
