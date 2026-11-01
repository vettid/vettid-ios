import Foundation
import VettIDCrypto

// The requests of "Votes" (IOS-PLAN §4.16, ANDROID-PLAN 0.1.108 §4 "Votes"; VAULT-MESSAGING 0.81.3 §10.19.8), one function
// per type. All are the owner app's alone (a desktop or an agent is `forbidden`). Every request about one proposal names
// `connection_id` together with `proposal_id` (0.81.2): the vault keys its records by the pair. A vault without the
// feature answers `unsupported_type`; a held vault `owner_check_required`. The bodies are returned as the vault sent them;
// VettIDData reads them. Mirrors vettid-android `VoteApi.kt`.
extension VaultApi {
    public static let typeVoteList = "vote.list"
    public static let typeVoteGet = "vote.get"
    public static let typeVoteCast = "vote.cast"
    public static let typeVoteCheck = "vote.check"
    public static let typeVoteConfirm = "vote.confirm"
    public static let typeVoteRelease = "vote.release"
    public static let typeVoteEvidence = "vote.evidence"
    public static let typeVoteSiteSync = "vote.site.sync"
    public static let typeVoteResultsSubmit = "vote.results.submit"
    /// The vault's event about a vote (V→D, the app only, 0.81.3).
    public static let typeVoteEvent = "vote.event"

    private func voteOp(_ type: String, _ body: JsonBuilder) async throws -> JsonObject {
        VaultJSON.object(try await device.op(type, body: body.bytes()))
    }

    private static func pair(_ connectionID: String, _ proposalID: String) -> JsonBuilder {
        JsonBuilder().string("connection_id", connectionID).string("proposal_id", proposalID)
    }

    /// `vote.list{state?, after?, limit?, ack_dropped?}`: `{votes, next?, dropped, problems, reconnect, list_version?,
    /// list_sha256?}`. [limit] 1–100 (the vault's default 50); [ackDropped] removes the `dropped` entries of those
    /// connections (0.81.3), sent only when not empty.
    public func voteList(
        state: String? = nil, after: String? = nil, limit: Int? = nil, ackDropped: [String] = []
    ) async throws -> JsonObject {
        let b = JsonBuilder()
        if let state { b.string("state", state) }
        if let after { b.string("after", after) }
        if let limit { b.uint("limit", UInt64(min(max(limit, 1), 100))) }
        if !ackDropped.isEmpty { b.raw("ack_dropped", JsonBuilder.array(ackDropped.map(JsonBuilder.quote))) }
        return try await voteOp(Self.typeVoteList, b)
    }

    /// `vote.get{connection_id, proposal_id}`: the vote with its text and choices (and the member's `choice_id` once cast).
    public func voteGet(connectionID: String, proposalID: String) async throws -> JsonObject {
        try await voteOp(Self.typeVoteGet, Self.pair(connectionID, proposalID))
    }

    /// `vote.cast{connection_id, proposal_id, choice_id}`: `{proposal_id, ballot: {state}}`. `credential_locked` means the
    /// unlock window is closed. The app never repeats it after an answer (§10.19.8).
    public func voteCast(connectionID: String, proposalID: String, choiceID: String) async throws -> JsonObject {
        try await voteOp(Self.typeVoteCast, Self.pair(connectionID, proposalID).string("choice_id", choiceID))
    }

    /// `vote.check{connection_id, proposal_id}`: asks the service `vote.status` now; `{}`.
    public func voteCheck(connectionID: String, proposalID: String) async throws {
        _ = try await voteOp(Self.typeVoteCheck, Self.pair(connectionID, proposalID))
    }

    /// `vote.confirm{connection_id, proposal_id, mine}`: the member's answer after a restore; `{ballot: {state}}`.
    public func voteConfirm(connectionID: String, proposalID: String, mine: Bool) async throws -> JsonObject {
        try await voteOp(Self.typeVoteConfirm, Self.pair(connectionID, proposalID).bool("mine", mine))
    }

    /// `vote.evidence{connection_id, proposal_id}`: `{evidence: {…}}`, to be written unchanged where the member puts it.
    public func voteEvidence(connectionID: String, proposalID: String) async throws -> JsonObject {
        try await voteOp(Self.typeVoteEvidence, Self.pair(connectionID, proposalID))
    }

    /// `vote.release{connection_id, proposal_id, utk_id, sealed}`: the vault [pin] alone sealed to a UTK, as `audit.export`
    /// carries it (§3.5.4). `evidence_not_exported` until `vote.evidence` was called after the record's last change;
    /// `bad_pin`, `backoff`, `utk_invalid`, `credential_frozen`, `rotation_required`, `not_found`, `bad_request`.
    public func voteRelease(connectionID: String, proposalID: String, pin: String) async throws {
        _ = try await credential.sealedOpAt(
            Self.typeVoteRelease, [.string("pin", pin)],
            outer: [("connection_id", JsonBuilder.quote(connectionID)), ("proposal_id", JsonBuilder.quote(proposalID))]
        )
    }

    /// `vote.site.sync{services?, services_confirm?, entries?}` with [body] as the caller built it, inline (at most 245,760
    /// bytes encoded): `{services?, services_confirm?, entries?}`.
    public func voteSiteSync(body: [UInt8]) async throws -> JsonObject {
        VaultJSON.object(try await device.op(Self.typeVoteSiteSync, body: body))
    }

    /// `vote.site.sync{blob: {id, key, sha256, size}}` (§10.19.8, §5.5): a request over 245,760 bytes, uploaded first as a
    /// claim-check blob to the app's own vault (`mime` and `name` absent).
    public func voteSiteSyncBlob(blobID: String, key: [UInt8], sha256: [UInt8], size: Int) async throws -> JsonObject {
        let blob = JsonBuilder().string("id", blobID).base64("key", key).base64("sha256", sha256).uint("size", UInt64(max(size, 0)))
        return try await voteOp(Self.typeVoteSiteSync, JsonBuilder().raw("blob", blob.build()))
    }

    /// `vote.results.submit{connection_id, proposal_id, results, results_sig, bundle, row, row_proof}` (§10.19.6) with
    /// [body] as the caller built it: `{proposal_id, check: {state, reason?}}`.
    public func voteResultsSubmit(body: [UInt8]) async throws -> JsonObject {
        VaultJSON.object(try await device.op(Self.typeVoteResultsSubmit, body: body))
    }
}
