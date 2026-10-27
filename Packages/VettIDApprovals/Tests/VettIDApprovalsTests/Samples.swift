import Foundation
import VettIDCrypto
@testable import VettIDData

/// Requests of every kind for the view-model tests.
enum Samples {
    static let t0 = Date(timeIntervalSince1970: 1_791_115_200)

    static func incoming(_ id: String = "p1", state: RequestState = .pending, at: Date = t0) -> PendingConnection {
        var r = ConnectionRequest(pendingID: id, sas: "042817", remote: false, name: "Ada Lovelace", receivedAt: at, exp: nil)
        r.state = state
        return .incoming(r)
    }

    static func outgoing(_ id: String = "o1", sas: String? = "042817", state: RequestState = .pending) -> PendingConnection {
        .outgoing(OutgoingRequest(connectionID: id, sas: sas, remote: true, name: "Grace Hopper", state: state, receivedAt: t0, exp: nil))
    }

    static func auth(_ id: String = "a1", conn: String = "c1", at: Date = t0, purpose: AuthenticationPurpose = .absent) -> PendingApproval {
        .authentication(
            AuthenticationRequest(requestID: id, connectionID: conn, context: "Sign-in", receivedAt: at, exp: nil, purpose: purpose)
        )
    }

    static func entry(_ ref: String, kind: String = "item", available: Bool = true, name: String? = "Passport") -> GrantEntry {
        GrantEntry(kind: kind, ref: ref, label: "Their words", available: available, name: name, category: nil, labels: nil)
    }

    static func grant(_ id: String = "g1", conn: String = "c1", at: Date = t0, entries: [GrantEntry]? = nil) -> PendingApproval {
        .grant(GrantRequest(
            requestID: id, connectionID: conn,
            entries: entries ?? [entry("i1"), entry("i2", available: false), entry("insurance", kind: "category", name: nil)],
            uses: 3, expiresIn: 86_400, reason: "Travel", receivedAt: at, exp: nil
        ))
    }

    static let payload = Base64s.encodeStd(Array("sign me".utf8))
    static let payloadSha = Base64s.encodeStd(Bytes.sha256(Array("sign me".utf8)))

    static func critical(
        _ id: String = "k1", conn: String = "c1", at: Date = t0, payload: String = payload, kind: String? = "password"
    ) -> PendingApproval {
        .critical(CriticalUse(
            requestID: id, connectionID: conn, itemName: "Signing key", fieldLabel: "Seed", operation: "sign", payload: payload,
            payloadSha256: payloadSha, context: nil, receivedAt: at, exp: nil, kind: kind
        ))
    }

    static func share(_ rule: String = "r1") -> PendingApproval {
        .share(ShareDecision(
            ruleID: rule, subjectConnectionID: "c1", subjectAgentID: nil,
            items: [
                ShareItem(itemID: "s1", name: "Blood type", category: "medical", sensitivity: "data", askRuleID: nil, shared: false),
                ShareItem(itemID: "s2", name: "Allergies", category: "medical", sensitivity: "data", askRuleID: "r9", shared: true),
            ],
            reason: "rule", receivedAt: t0
        ))
    }

    static func device(_ type: String = "approval.pending") -> PendingApproval {
        .device(DeviceRequest(type: type, id: "d1", deviceName: "Laptop", role: "desktop", requestType: "sign", receivedAt: t0, exp: nil))
    }

    static func connection(_ id: String, first: String? = "Sam", paused: Bool = false) -> ConnectionInfo {
        var c = ConnectionInfo(id: id, name: "", state: .active)
        c.firstName = first
        c.lastName = first == nil ? nil : "Lee"
        if paused { c.asks = AskState(paused: true) }
        return c
    }
}
