import Foundation
import Testing
import VettIDData
@testable import VettIDHistory
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The kinds of VAULT-MESSAGING §10.9 have titles and groups; unknown kinds read generically; the signer entries read
/// their `ref`; the export summary; every text resolves. Mirrors vettid-android `AuditKindsTest`, `CategoryHueTest`
/// (the 0.23.0 kinds) and `HistorySignerTest`.
@Suite struct AuditKindsTests {
    /// Every kind §10.9 lists (the `drop.<reason>` family and `<kind>.summary` aside).
    static let specKinds = [
        "vault.unlocked", "vault.locked", "device.paired", "device.unlinked", "connection.added", "connection.removed",
        "connection.stale", "connection.reconnected", "identity.rotated", "credential.created", "credential.rotated",
        "credential.password_changed", "credential.password_failed", "credential.unlocked", "credential.recovered",
        "credential.clone_detected", "credential.alarm.confirmed", "credential.alarm.resolved", "credential.reset",
        "vault.pin_failed", "owner_check.passed", "owner_check.held", "owner_check.failed", "owner_check.locked",
        "owner_check.hold_changed", "device.transfer.started", "device.transfer.approved", "device.transferred",
        "device.transfer.aborted", "device.transfer.attestation_failed", "device.replaced", "item.added", "item.updated",
        "item.deleted", "item.sensitivity_changed", "item.revealed", "tag.changed", "settings.changed",
        "account.name_requested", "account.name_applied", "account.name_refused", "profile.core_missing",
        "recovery.requested", "recovery.replaced", "recovery.bad_code", "recovery.attestation_failed",
        "recovery.registered", "recovery.device_paired", "recovery.completed", "recovery.cancelled", "recovery.expired",
        "recovery.voided", "message.sent", "message.received", "connection.blocked", "connection.unblocked",
        "connection.request.peer_declined", "connection.authenticate.requested", "connection.authenticate.signed",
        "connection.authenticate.denied", "connection.authenticated", "connection.authenticate_failed",
        "device.session.granted", "device.session.ended", "approval.granted", "approval.denied",
        "connection.authenticate.key_rotated", "connection.authenticate.rotation_rejected", "call.outgoing",
        "call.incoming", "call.answered", "call.ended", "leash.grant.issued", "leash.grant.updated", "leash.grant.revoked",
        "leash.rate_limited", "leash.agent.suspended", "leash.agent.resumed", "leash.referrals_limited", "leash.allowed",
        "leash.refused", "leash.item.read", "leash.item.used", "leash.throttled", "grant.requested", "grant.denied",
        "grant.issued", "grant.received", "grant.fetched", "grant.revoked", "share.rule.created", "share.rule.updated",
        "share.rule.deleted", "share.included", "share.declined", "share.withdrawn", "critical-secret.use.requested",
        "critical-secret.used", "critical-secret.use.denied", "critical-secret.use.result", "action.configured",
        "action.invoked", "action.approved", "action.denied", "action.completed", "intro.created", "intro.offered",
        "intro.accepted", "intro.declined", "intro.connecting", "intro.closed", "location.share.started",
        "location.share.stopped", "location.share.received", "location.share.ended", "location.requested",
        "location.history.deleted", "location.history.shared", "location.history.received", "wallet.created",
        "wallet.deleted", "wallet.address_issued", "wallet.signed", "drop.suppressed", "audit.exported",
        "device.signer_bound", "device.signer_changed", "device.signer_refused",
        // VAULT-MESSAGING 0.49.1, IOS-PLAN §4.1: the fixed titles.
        "vault.pin_changed", "device.secret_renewed", "recovery.armed", "recovery.presence_unrecorded",
        "identity.rotation_failed", "connection.request.approved", "connection.request.declined",
    ]

    static func knownKey(_ kind: String) -> String? {
        if case .known(let k) = AuditKinds.title(kind) { return k }
        return nil
    }

    @Test func everySpecKindHasATitleAndAGroup() {
        for k in Self.specKinds {
            #expect(Self.knownKey(k) != nil, "\(k)")
            #expect(AuditCategory.of(k) != .other, "\(k)")
        }
    }

    @Test func theTitlesAreDistinct() {
        let keys = Self.specKinds.compactMap(Self.knownKey)
        #expect(keys.count == Self.specKinds.count && Set(keys).count == keys.count)
        let texts = keys.map { HistoryKindTexts.text($0) }
        #expect(Set(texts).count == texts.count)
    }

    @Test func everyKindFallsInExactlyOneCategory() {
        for k in Self.specKinds {
            #expect(AuditCategory.filters.count { c in c.prefixes.contains { AuditCategory.matches(k, prefix: $0) } } == 1, "\(k)")
        }
        #expect(AuditCategory.filters.count == 10 && !AuditCategory.filters.contains(.other))
    }

    @Test func aHistoryExportIsUnderSecurityWithItsSummary() {
        #expect(AuditCategory.of("audit.exported") == .security)
        #expect(AuditKinds.title("audit.exported") == .known("history_kind_audit_exported"))
        let ref = "format=csv;count=40;seqs=700-790;filters=kinds,dates;since=2026-10-01T04:00:00.000Z"
        #expect(AuditKinds.exportSummary("audit.exported", ref)! == ("csv", 40))
        #expect(AuditKinds.exportSummary("audit.exported", "format=json;count=812;seqs=1-812;filters=none")! == ("json", 812))
        #expect(AuditKinds.exportSummary("audit.exported", "count=1") == nil)
        #expect(AuditKinds.exportSummary("audit.exported", "format=xml;count=1") == nil)
        #expect(AuditKinds.exportSummary("item.added", "format=csv;count=1") == nil)
        #expect(HistoryText.exportSummary("audit.exported", ref) == "CSV · 40 entries")
        #expect(HistoryText.exportSummary("audit.exported", "format=json;count=1") == "JSON · 1 entry")
    }

    /// 0.27.0 §10.9, §11.7.1: the signer entries are Devices entries whose `ref` names classes, in plain words.
    @Test func theSignerEntriesReadTheirRef() {
        for k in ["device.signer_bound", "device.signer_changed", "device.signer_refused"] {
            #expect(AuditCategory.of(k) == .devices && Self.knownKey(k) != nil)
        }
        #expect(AuditKinds.signerDetail("device.signer_bound", "vettid") == .bound("vettid"))
        #expect(AuditKinds.signerDetail("device.signer_changed", "vettid:google_play") == .changed(from: "vettid", to: "google_play"))
        #expect(AuditKinds.signerDetail("device.signer_refused", "unpinned") == .refused(unbound: false))
        #expect(AuditKinds.signerDetail("device.signer_refused", "unbound") == .refused(unbound: true))
        #expect(AuditKinds.signerDetail("device.signer_changed", "vettid") == nil)
        #expect(AuditKinds.signerDetail("device.signer_changed", "a:b:c") == nil)
        #expect(AuditKinds.signerDetail("device.signer_bound", nil) == nil)
        #expect(AuditKinds.signerDetail("device.signer_refused", "other") == nil)
        #expect(AuditKinds.signerDetail("device.paired", "vettid") == nil)
        #expect(HistoryText.title("device.signer_bound") == "Version of VettID recorded for this vault")
        #expect(HistoryText.title("device.signer_changed") == "Vault moved to another version of VettID")
        #expect(HistoryText.title("device.signer_refused") == "An installation of VettID was refused")
        #expect(HistoryText.signer(.refused(unbound: false)) == "This vault release does not accept its signer")
        #expect(HistoryText.signer(.refused(unbound: true)) == "No signer was recorded for it")
        #expect(HistoryText.signer(.changed(from: "development", to: "vettid")).hasPrefix("From "))
        #expect(HistoryText.signer(.bound("vettid")).first?.isUppercase == true)
    }

    @Test func droppedSummaryAndUnknown() {
        #expect(AuditKinds.title("drop.peer_unknown") == .dropped("peer unknown"))
        #expect(AuditKinds.title("drop.owner_check") == .known("history_kind_drop_owner_check"))
        #expect(AuditKinds.title("leash.item.read.summary") == .summary("history_kind_leash_item_read"))
        #expect(AuditKinds.title("zebra.new") == .unknown("zebra.new"))
        #expect(AuditKinds.title("drop.") == .unknown("drop."))
        #expect(HistoryText.title("drop.peer_unknown") == "Message blocked: peer unknown")
        #expect(HistoryText.title("leash.item.read.summary") == "Agent read an item (hourly summary)")
        #expect(HistoryText.title("zebra.new") == "Vault event: zebra.new")
    }

    /// 0.23.0 §10.4.1, §10.12: suppressed asks under Dropped, the asks' changes under Connections.
    @Test func theAsksKindsHaveTitlesAndGroups() {
        for k in ["drop.ask_muted", "drop.ask_paused", "drop.ask_cooldown", "drop.ask_pending", "drop.ask_rate", "drop.grant_rate_limited"] {
            #expect(Self.knownKey(k) == "history_kind_" + k.replacingOccurrences(of: ".", with: "_") && AuditCategory.of(k) == .dropped, "\(k)")
        }
        for k in ["connection.asks_paused", "connection.asks_resumed", "connection.asks_muted", "connection.asks_unmuted"] {
            #expect(Self.knownKey(k) == "history_kind_" + k.replacingOccurrences(of: ".", with: "_") && AuditCategory.of(k) == .connections, "\(k)")
        }
    }

    @Test func everyGroupHasItsOwnLabel() {
        let labels = AuditCategory.allCases.map(AuditKinds.categoryLabel)
        #expect(Set(labels).count == labels.count)
        #expect(AuditKinds.categoryLabel(.vaultAccess) == "Unlocks and daily checks")
        #expect(AuditKinds.categoryLabel(.items) == "Vault (items, sharing, wallet)")
    }

    /// §10.9: the kinds whose `ref` names an item (rows show its name; the detail opens it).
    @Test func itemEntriesNameTheirItem() {
        #expect(AuditKinds.itemOf("item.revealed", "01ITEM") == "01ITEM")
        #expect(AuditKinds.itemOf("share.withdrawn", "01ITEM") == "01ITEM")
        #expect(AuditKinds.itemOf("leash.item.changed", "01ITEM") == "01ITEM")
        #expect(AuditKinds.itemOf("message.received", "m-1") == nil)
        #expect(AuditKinds.itemOf("item.added", nil) == nil)
        #expect(AuditKinds.itemOf("item.added", "") == nil)
        #expect(AuditKinds.itemOf("share.pending", "01RULE") == nil)
    }

    /// Every key of the package's table resolves, in the built bundle, to its own non-empty text: vettid-android's
    /// `strings.xml` (113) and `strings_kinds.xml` (228). Every key the code names is in it.
    @Test func everyStringResolves() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDHistory/Resources/Localizable.xcstrings")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = try #require((doc["strings"] as? [String: Any])?.keys)
        #expect(keys.count == 341)
        let missing = "\u{0}missing"
        for key in keys {
            let text = HistoryKindTexts.bundle.localizedString(forKey: key, value: missing, table: nil)
            #expect(!text.isEmpty && text != key && text != missing, "\(key)")
            #expect(key.hasPrefix("history_"), "\(key)")
        }
        // The kinds' table in the code is the same as the bundle's.
        #expect(Set(HistoryKindTexts.english.keys).isSubset(of: Set(keys)) && HistoryKindTexts.english.count == 228)
        let named = AuditKinds.named.values.flatMap { t -> [String] in if case .named(let a, let b, _) = t { [a, b] } else { [] } }
        for key in Array(AuditKinds.titles.values) + named {
            #expect(HistoryKindTexts.english[key] != nil, "\(key)")
        }
    }
}

// swiftlint:enable line_length
