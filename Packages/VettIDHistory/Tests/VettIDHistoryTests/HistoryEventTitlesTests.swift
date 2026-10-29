import Foundation
import Testing
import VettIDData
@testable import VettIDHistory
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// History's titles, detail lines and hidden kinds of IOS-PLAN §4.1 (approved by the owner, 2026-10-19 and 2026-10-20).
/// Mirrors the titles part of vettid-android `HistoryEventTitlesTest`.
@Suite struct HistoryEventTitlesTests {
    func lines(_ kind: String, _ ref: String?, _ outcome: AuditKinds.Outcome = .unknown, scale: UInt64 = 1) -> [String] {
        HistoryText.details(kind, ref, outcome: outcome, timeScale: scale)
    }

    @Test func theTitlesReadAsApproved() {
        let expected: [(String, String?, String)] = [ // swiftlint:disable:this large_tuple
            ("vault.pin_changed", nil, "PIN changed"),
            ("device.secret_renewed", nil, "New phone secret set"),
            ("identity.rotated", nil, "Your vault's keys were renewed"),
            ("credential.rotated", nil, "Your credential was renewed"),
            ("credential.utk_resync", nil, "One-time keys renewed"),
            ("credential.holder_cleared", nil, "Credential holder cleared"),
            ("owner_check.passed", nil, "Daily check passed"),
            ("owner_check.held", nil, "Vault held for the daily check"),
            ("owner_check.failed", "pin", "Daily check failed"),
            ("owner_check.locked", "10", "Vault locked after failed daily checks"),
            ("owner_check.hold_changed", "on", "Daily check hold changed"),
            ("recovery.attempt", "2/3/not_success/counter", "Recovery attempt 3 of 10"),
            ("recovery.attempt", "garbled", "Recovery attempt"),
            ("recovery.attempts_used", "2/4", "Recovery attempts used: 4 of 10"),
            ("recovery.attempts_used", "x", "Recovery attempts used"),
            ("recovery.armed", "3", "Recovery is set up"),
            ("recovery.generation_closed", "2/pin", "Recovery attempts reset after a PIN change"),
            ("recovery.generation_closed", "2/password", "Recovery attempts reset after a password change"),
            ("recovery.generation_closed", "2/reset", "Recovery attempts reset after a credential reset"),
            ("recovery.generation_closed", "2/backup_off", "Recovery turned off"),
            ("recovery.generation_closed", "2/exhausted", "Recovery turned off: all 10 attempts used"),
            ("recovery.generation_closed", "2/delete", "Recovery ended"),
            ("recovery.generation_closed", "2/delete/unconfirmed", "Recovery ended"),
            ("recovery.generation_closed", "2/newer", "Recovery attempts reset"),
            ("recovery.generation_closed", "4/rollback", "Your vault was given an older recovery record"),
            ("recovery.presence_unrecorded", nil, "Your vault could not record that you were here"),
            ("identity.rotation_failed", "recovery", "Key update failed"),
            ("connection.request.approved", "p1", "You accepted a connection request"),
            ("connection.request.declined", "p1", "You declined a connection request"),
            ("drop.call_off", nil, "Call refused: calls are off"),
            ("drop.call_rate", nil, "Call refused: too many calls"),
            ("drop.call_share", nil, "Call refused: it could not be verified"),
            ("drop.one_app", nil, "Refused: a second phone tried to connect"),
            ("drop.owner_check", nil, "Refused: your daily check is due"),
            ("drop.profile_ik_mismatch", nil, "Profile refused: it did not match the connection"),
            ("drop.profile_malformed", nil, "Message refused: it was malformed"),
            ("drop.location_malformed", nil, "Message refused: it was malformed"),
            ("drop.attachment_malformed", nil, "Photo refused: it was malformed"),
            ("drop.grant_duplicate", nil, "Request refused: already asked"),
            ("drop.grant_limit", nil, "Request refused: too many waiting"),
            ("drop.critical_signature", nil, "Request refused: it could not be verified"),
            ("drop.rate_limited", nil, "Message refused: too many messages"),
        ]
        for (kind, ref, text) in expected { #expect(HistoryText.title(kind, ref) == text, "\(kind) \(ref ?? "-")") }
        #expect(HistoryStrings.categoryVaultAccess == "Unlocks and daily checks")
    }

    /// A received name that closes the isolation and reverses what follows (PDI then RLO) is cleaned; in a file it is cleaned
    /// and not isolated (VAULT-MESSAGING §10.8; mirrors vettid-android #220).
    @Test func aHostileNameCannotReverseTheTitle() {
        let n = EntryNames(connection: "Bank\u{2069}\u{202E}")
        let title = HistoryText.title("call.permission_off", names: n)
        #expect(title == "Calls from \u{2068}Bank\u{2069} turned off")
        #expect(title.filter { $0 == "\u{2069}" }.count == 1 && !title.contains("\u{202E}"))
        #expect(HistoryText.title("call.permission_off", names: n, isolate: false) == "Calls from Bank turned off")
        #expect(HistoryText.title("call.permission_off", names: EntryNames(connection: "\u{2069}\u{202E}")) == "Calls turned off")
    }

    @Test func namedTitlesShowTheConnectionDeviceOrItem() {
        let n = EntryNames(connection: "Sam Lee", device: "Pixel 7", item: "GitHub token")
        #expect(HistoryText.title("identity.rotate_conflict", names: n) == "Connection with \u{2068}Sam Lee\u{2069} paused")
        #expect(HistoryText.title("identity.rotate_resolved", "fp", names: n) == "Connection with \u{2068}Sam Lee\u{2069} checked and resumed")
        #expect(HistoryText.title("call.permission_off", names: n) == "Calls from \u{2068}Sam Lee\u{2069} turned off")
        #expect(HistoryText.title("call.permission_on", names: n) == "Calls from \u{2068}Sam Lee\u{2069} turned on")
        #expect(HistoryText.title("push.registered", "fcm", names: n) == "Notifications turned on for \u{2068}Pixel 7\u{2069}")
        #expect(HistoryText.title("push.unregistered", "app", names: n) == "Notifications turned off for \u{2068}Pixel 7\u{2069}")
        #expect(HistoryText.title("push.token_gone", "token_gone", names: n) == "Notifications stopped reaching \u{2068}Pixel 7\u{2069}")
        #expect(HistoryText.title("leash.item.run", "01ITEM", names: n) == "An agent used \u{2068}GitHub token\u{2069}")
        #expect(HistoryText.title("leash.item.proxy", "01ITEM", names: n) == "An agent used \u{2068}GitHub token\u{2069}")
        #expect(HistoryText.title("leash.item.changed", "01ITEM", names: n) == "You changed how an agent may use \u{2068}GitHub token\u{2069}")
        // Without the name (gone or not known), the title drops it.
        #expect(HistoryText.title("identity.rotate_conflict") == "Connection paused")
        #expect(HistoryText.title("identity.rotate_resolved") == "Connection checked and resumed")
        #expect(HistoryText.title("call.permission_off") == "Calls turned off")
        #expect(HistoryText.title("call.permission_on") == "Calls turned on")
        #expect(HistoryText.title("push.registered", "fcm") == "Notifications turned on")
        #expect(HistoryText.title("push.unregistered", "app") == "Notifications turned off")
        #expect(HistoryText.title("push.token_gone") == "Notifications stopped")
        #expect(HistoryText.title("leash.item.run", "01GONE") == "An agent used an item")
        #expect(HistoryText.title("leash.item.changed") == "You changed how an agent may use an item")
    }

    @Test func theDetailLinesReadAsApproved() {
        let attempt = "2/3/not_success/counter"
        let notYou = "Not successful. If this was not you, change your PIN or your password now."
        #expect(lines("recovery.attempt", "2/4/success/counter") == ["Successful."])
        #expect(lines("recovery.attempt", attempt) == [notYou])
        #expect(lines("recovery.attempt", attempt, AuditKinds.Outcome.none) == [notYou, "Details not available."])
        let outcomes = [
            "wrong": "Wrong PIN or password.",
            "attempt_lost": "Counted as an attempt, but it did not finish.",
            "quiet": "Refused: you used your vault in the last 3 days.",
            "wait": "Refused: too soon after the last try.",
            "exhausted": "Refused: all 10 attempts used.",
            "closed": "Refused: recovery was reset.",
        ]
        for (o, text) in outcomes { #expect(lines("recovery.attempt", attempt, .matched(o)) == [notYou, text], "\(o)") }
        // An outcome this app does not know: no line of its own.
        #expect(lines("recovery.attempt", attempt, .matched("busy")) == [notYou])
        #expect(lines("recovery.attempt", "garbled", AuditKinds.Outcome.none).isEmpty)
        #expect(lines("recovery.attempt", attempt, .laterSuccessful) == ["Later successful."])
        #expect(lines("recovery.generation_closed", "4/rollback") == ["A host may have served an older copy of your vault's recovery record, one on which recovery attempts had already been used. Your vault moved past it. If you did not try to recover your vault, change your PIN and your password now, and contact VettID."])
        #expect(lines("recovery.generation_closed", "4/stale").isEmpty)
        // The attempting phone's self-reported name, only in that form; nothing without one.
        #expect(lines("recovery.attempt", attempt, .matched("wrong", phoneName: "Pixel 7")) == [notYou, "Wrong PIN or password.", "From a phone that calls itself “\u{2068}Pixel 7\u{2069}”."])
        #expect(lines("recovery.attempt", attempt, .matched("wrong")) == [notYou, "Wrong PIN or password."])
        #expect(HistoryText.title("recovery.attempt", attempt) == "Recovery attempt 3 of 10")
        #expect(lines("recovery.attempts_used", "2/4") == ["If that was not you, change your password now, and your PIN as well."])
        #expect(lines("recovery.armed", "3") == ["It works with your current PIN and password, with 10 attempts."])
        for r in ["pin", "password", "reset"] { #expect(lines("recovery.generation_closed", "2/\(r)") == ["Earlier attempts no longer count."]) }
        #expect(lines("recovery.generation_closed", "2/backup_off") == ["You turned off the credential backup."])
        #expect(lines("recovery.generation_closed", "2/exhausted") == ["Change your PIN or your password to turn it back on."])
        #expect(lines("recovery.generation_closed", "2/delete") == ["Your vault is being deleted."])
        #expect(lines("recovery.generation_closed", "2/delete/unconfirmed") == ["Your vault is being deleted.", "The service could not confirm this step."])
        #expect(lines("recovery.presence_unrecorded", nil) == ["If this lasts three days, your vault is no longer protected against a recovery started by someone else."])
        // VAULT-MESSAGING 0.69.2 §11.14.10: the move's line only for a transfer's rotation.
        #expect(lines("identity.rotated", "t-1") == ["Replaced when you moved your vault to a new phone."])
        #expect(lines("identity.rotated", "recovery").isEmpty && lines("identity.rotated", nil).isEmpty && lines("identity.rotated", "").isEmpty)
        #expect(lines("identity.rotation_failed", "recovery") == ["Your connections still know your old keys. VettID will offer the update again."])
        #expect(lines("identity.rotate_conflict", nil) == ["This connection's vault announced two different new keys. That can mean someone holds an old copy of their vault. Nothing is sent or received until you check."])
        #expect(lines("push.registered", "fcm") == ["Through Google."])
        #expect(lines("push.registered", "apns") == ["Through Apple."])
        #expect(lines("push.registered", "other").isEmpty)
        #expect(lines("push.unregistered", "app") == ["Turned off on that phone."])
        #expect(lines("push.unregistered", "transferred") == ["Your vault moved to a new phone."])
        #expect(lines("push.unregistered", "replaced") == ["That phone was replaced after a recovery."])
        #expect(lines("push.token_gone", "blob_invalid") == ["Open VettID on that phone to turn them back on."])
        #expect(lines("leash.item.run", "01ITEM") == ["The secret went to your VettID connector for one command on your computer. The agent was not given it."])
        #expect(lines("leash.item.proxy", "01ITEM") == ["The secret went to your VettID connector, which added it to the agent's requests to a site you allowed. The agent was not given it."])
        #expect(lines("credential.utk_resync", nil) == ["This phone's one-time keys were replaced with a fresh set."])
        #expect(lines("credential.holder_cleared", nil) == [
            "Your vault found its credential holder missing and cleared it. If you didn't remove a phone, contact VettID.",
        ])
        #expect(lines("vault.unlocked", nil).isEmpty)
    }

    /// On a vault with a time scale the waits the vault divides are said as it runs them (STAGING-TIME-SCALE).
    @Test func aScaledVaultSaysItsOwnWaits() {
        let staging = lines("recovery.presence_unrecorded", nil, scale: 24)
        #expect(staging.count == 1 && staging[0].hasPrefix("If this lasts 3 hours,"))
        let quiet = lines("recovery.attempt", "2/3/not_success/counter", .matched("quiet"), scale: 24)
        #expect(quiet.last == "Refused: you used your vault in the last 3 hours.")
    }

    /// Decision 4: four kinds are read but not listed; they stay in the entries for the chain check and the export.
    @Test func theHiddenKindsAreNotShown() {
        #expect(AuditKinds.hidden("recovery.open", "01JREC/wrong"))
        #expect(AuditKinds.hidden("recovery.generation_closed", "4/stale"))
        #expect(!AuditKinds.hidden("recovery.generation_closed", "4/rollback"))
        #expect(AuditKinds.hidden("device.unlinked_sent", "01JTRANSFER"))
        #expect(AuditKinds.hidden("drop.call_glare", "call1"))
        #expect(!AuditKinds.hidden("recovery.generation_closed", "4/pin"))
        #expect(!AuditKinds.hidden("recovery.generation_closed", nil))
        #expect(!AuditKinds.hidden("recovery.attempt", "2/3/not_success/counter"))
        #expect(!AuditKinds.hidden("drop.call_off", "call1"))
        func rec(_ seq: Int64, _ kind: String, _ ref: String? = nil) -> AuditRecord {
            AuditRecord(AuditEntry(entryID: "e\(seq)", seq: seq, at: "2026-10-19T12:00:00.000Z", kind: kind, ref: ref))
        }
        var s = HistoryState()
        s.entries = [rec(5, "recovery.attempt", "2/3/not_success/counter"), rec(4, "recovery.open", "01JREC/wrong"), rec(3, "recovery.generation_closed", "4/stale"), rec(2, "device.unlinked_sent", "t1"), rec(1, "drop.call_glare")]
        #expect(s.shown.map(\.seq) == [5] && s.entries.count == 5)
    }
}

// swiftlint:enable line_length
