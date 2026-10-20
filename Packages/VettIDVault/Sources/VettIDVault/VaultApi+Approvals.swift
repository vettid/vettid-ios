import Foundation
import VettIDCrypto

// The member's decisions on what waits for them (ANDROID-PLAN §4 Approvals): member authentication (VAULT-MESSAGING
// §10.4), grant requests and share decisions (§10.12), critical-item uses (§10.13). One function per type, the shapes of
// vettid-vault `features/grants`, `features/critical`, `features/items` and `features/connauth`. Desktop and agent
// requests (§6.8) are ``sessionDeny(_:)`` and ``approvalDecide(_:approve:)``. Mirrors the approvals part of
// vettid-android `VaultApi`.
extension VaultApi {
    private func approvalOp(_ type: String, _ body: JsonBuilder) async throws -> JsonObject {
        VaultJSON.object(try await device.op(type, body: body.bytes()))
    }

    // MARK: - Member authentication (§10.4)

    /// `connection.authenticate.request`: asks the connection's member to prove presence; returns the `request_id`.
    public func authenticateRequest(_ connectionID: String, context: String? = nil) async throws -> String {
        let b = JsonBuilder().string("connection_id", connectionID)
        if let context { b.string("context", context) }
        return VaultJSON.string(try await approvalOp("connection.authenticate.request", b), "request_id") ?? ""
    }

    /// `connection.authenticate.approve`: signs the challenge with the credential key; the unlock window must be open
    /// (`credential.unlock` first, else `credential_locked`). `not_found` for a request that ended.
    public func authenticateApprove(_ requestID: String) async throws {
        _ = try await approvalOp("connection.authenticate.approve", JsonBuilder().string("request_id", requestID))
    }

    /// `connection.authenticate.deny`: a decline (§10.4.1: it starts the cooldown).
    public func authenticateDeny(_ requestID: String) async throws {
        _ = try await approvalOp("connection.authenticate.deny", JsonBuilder().string("request_id", requestID))
    }

    /// `connection.authenticate.list`: `{states: [{connection_id, verified_at?, last_result?, last_at?}]}`.
    public func authenticateList() async throws -> JsonObject {
        try await approvalOp("connection.authenticate.list", JsonBuilder())
    }

    // MARK: - Grants (§10.12)

    /// `grant.list`: `{given, received, pending, requested}`; `pending` holds the connections' requests waiting for the
    /// member, each `{request_id, connection_id, items: [{kind, ref, fields?, label?, available, name?, category?,
    /// labels?}], uses, expires_in, reason?, exp}`.
    public func grantList() async throws -> JsonObject { try await approvalOp("grant.list", JsonBuilder()) }

    /// `grant.decide` of a connection's request. [approve] false denies the whole request (a decline, §10.4.1); approving
    /// sends the member's [choice]. Returns `{grants: [{grant_id, kind, ref}]}`; `bad_request` when nothing could be
    /// granted, `not_found` for a request that ended, `connection_unavailable`.
    public func grantDecide(_ requestID: String, approve: Bool, choice: GrantChoice = GrantChoice()) async throws -> JsonObject {
        let b = JsonBuilder().string("request_id", requestID).bool("approve", approve)
        let (items, answers, uses, expiresIn) = (choice.items, choice.answers, choice.uses, choice.expiresIn)
        if let items { b.raw("items", JsonBuilder.array(items.map { String(max($0, 0)) })) }
        if let answers, !answers.isEmpty {
            b.raw("answers", JsonBuilder.array(answers.map { a in
                let o = JsonBuilder().uint("index", UInt64(max(a.index, 0))).string("item_id", a.itemID)
                if let f = a.fields { o.raw("fields", JsonBuilder.array(f.map(JsonBuilder.quote))) }
                return o.build()
            }))
        }
        if let uses { b.uint("uses", UInt64(max(uses, 1))) }
        if let expiresIn { b.uint("expires_in", UInt64(max(expiresIn, 0))) }
        return try await approvalOp("grant.decide", b)
    }

    // MARK: - Share decisions (§10.12)

    /// `share.decide` (0.21.0): includes [include] and declines [decline], items of one rule's question, in one flush
    /// (nothing changed on an error). A vault before 0.21.0 answers `bad_request`: ``shareDecide(_:items:approve:)``.
    public func shareDecide(_ ruleID: String, include: [String], decline: [String]) async throws -> JsonObject {
        let b = JsonBuilder().string("rule_id", ruleID)
        if !include.isEmpty { b.raw("include", JsonBuilder.array(include.map(JsonBuilder.quote))) }
        if !decline.isEmpty { b.raw("decline", JsonBuilder.array(decline.map(JsonBuilder.quote))) }
        return try await approvalOp("share.decide", b)
    }

    /// `share.decide{items, approve}`: includes or declines the listed items of a rule's question.
    public func shareDecide(_ ruleID: String, items: [String], approve: Bool) async throws -> JsonObject {
        let b = JsonBuilder().string("rule_id", ruleID).raw("items", JsonBuilder.array(items.map(JsonBuilder.quote)))
        b.bool("approve", approve)
        return try await approvalOp("share.decide", b)
    }

    // MARK: - Critical-item uses (§10.13)

    /// `critical-secret-use.list`: `{incoming: [{request_id, connection_id, item_id, field_id, name, label, kind?,
    /// operation, payload_sha256, context?, exp}], outgoing: [...]}` (the incoming entries carry no `payload`).
    public func criticalUseList() async throws -> JsonObject {
        try await approvalOp("critical-secret-use.list", JsonBuilder())
    }

    /// `critical-secret-use.get` (0.10.2): an incoming request with its `payload`, the `critical-secret-use.pending`
    /// body. The caller checks SHA-256(payload) against `payload_sha256` before showing it or offering the approval.
    public func criticalUseGet(_ requestID: String) async throws -> JsonObject {
        try await approvalOp("critical-secret-use.get", JsonBuilder().string("request_id", requestID))
    }

    /// `critical-secret-use.approve`: one use, consented with the credential [password] (a credential operation). The
    /// sealed payload binds the password to [requestID] and to [payloadSha256], the hash of the payload the member saw;
    /// `request_id` also travels beside it. Returns the `status` the connection receives (`ok`, `unsuitable`,
    /// `unavailable`). `bad_password` and `backoff` leave the request pending.
    public func criticalUseApprove(_ requestID: String, password: String, payloadSha256: [UInt8]) async throws -> String? {
        let fields: [SealedField] = [
            .string("password", password), .string("request_id", requestID), .string("payload_sha256", Base64s.encodeStd(payloadSha256)),
        ]
        let body = try await credential.credOp("critical-secret-use.approve", fields, CredOpOptions(outer: [("request_id", requestID)]))
        return VaultJSON.string(VaultJSON.object(body), "status")
    }

    /// `critical-secret-use.deny`: a decline (§10.4.1); the connection gets `denied`.
    public func criticalUseDeny(_ requestID: String) async throws {
        _ = try await approvalOp("critical-secret-use.deny", JsonBuilder().string("request_id", requestID))
    }
}

/// The member's choice in a grant approval (`grant.decide`, §10.12): [items] the indexes granted (nil: all), [answers]
/// the member's item for a category entry, [uses] and [expiresIn] (seconds) the member's choice (nil: as asked).
public struct GrantChoice: Equatable, Sendable {
    public var items: [Int]?
    public var answers: [GrantAnswer]?
    public var uses: Int?
    public var expiresIn: Int?

    public init(items: [Int]? = nil, answers: [GrantAnswer]? = nil, uses: Int? = nil, expiresIn: Int? = nil) {
        self.items = items
        self.answers = answers
        self.uses = uses
        self.expiresIn = expiresIn
    }
}

/// The member's item that answers a grant request's category entry (`grant.decide` `answers`, §10.12): the entry's
/// [index], the item, and the fields granted (nil: as the entry asked).
public struct GrantAnswer: Equatable, Sendable {
    public var index: Int
    public var itemID: String
    public var fields: [String]?

    public init(index: Int, itemID: String, fields: [String]? = nil) {
        self.index = index
        self.itemID = itemID
        self.fields = fields
    }
}
