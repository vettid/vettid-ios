import Foundation
import VettIDCrypto
import VettIDVault

/// TEST ONLY. The part of vettid-vault `features/vote` the app's list reads (VAULT-MESSAGING 0.81.3 §10.19.8): `vote.list`
/// over the summaries the test sets, and `vote.event` to this phone. A vault without the feature (the default) answers
/// `unsupported_type`, as one before 0.81.0 does. The cast and the rest are answered by the unit tests' own fake.
extension FakeVaultService {
    /// Callers hold ``cond``.
    func voteRequest(_ m: Inner, _ body: JsonObject) throws {
        activity.voteRequests.append(m.type)
        activity.voteBodies.append((m.type, body))
        guard let votes = activity.votes else { return try reply(m.type, "{}", re: m.id, error: "unsupported_type") }
        switch m.type {
        case "vote.list":
            try reply(m.type, #"{"votes":\#(JsonBuilder.array(votes)),"dropped":[],"problems":[],"reconnect":[]}"#, re: m.id)
        case "vote.release":
            // The PIN alone, sealed to a UTK (§3.5.4), as `audit.export` carries it.
            guard let p = try opened(m, body) else { return }
            activity.votePins.append((try? p.string("pin")) ?? "")
            try reply(m.type, "{}", re: m.id)
        default:
            try reply(m.type, "{}", re: m.id, error: "not_found")
        }
    }

    // MARK: - What the test does and reads

    /// The vault holds these votes (`vote.list` summaries, encoded); nil: it has no votes feature.
    public func setVotes(_ summaries: [String]?) { locked { activity.votes = summaries } }

    /// A vote changed (`vote.event`, §10.19.8): this phone gets the event.
    public func voteEventArrives(connectionID: String, proposalID: String, event: String, state: String) throws {
        try locked {
            let body = JsonBuilder().string("proposal_id", proposalID).string("connection_id", connectionID)
                .string("event", event).string("state", state)
            try reply("vote.event", body.build())
        }
    }

    /// The `vote.*` requests the vault received, in order.
    public var voteRequests: [String] { locked { activity.voteRequests } }

    /// The bodies of the `vote.*` requests the vault received, in order.
    public var voteBodies: [(type: String, body: JsonObject)] { locked { activity.voteBodies } }

    /// The PINs `vote.release` carried, opened from their UTK seal.
    public var votePins: [String] { locked { activity.votePins } }
}
