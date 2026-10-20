#if DEBUG
import Foundation
import VettIDCrypto
import VettIDTesting

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

// TEST ONLY. The daily owner check (VAULT-MESSAGING §3.6) as vettid-vault answers it (`vault/ownercheck.go`,
// `features/credential/ownercheck.go`, `vault/oneapp.go` `verifyPIN`, `features/credential/credential.go` `openChecked`),
// on the vault's own clock (``advanceVaultClock(_:)``, the dev stack's clock): the first `credential.create` starts it;
// past the deadline the app may send only the check and what it needs (`owner_check_required`), and `vault.held` says
// what waits; `vault.owner-check` checks the blob (`stale_credential`), the PIN under the unlock's backoff, then the
// password under its own (after 5 failures in a row: 30 s, 1 min, 5 min, 15 min, 60 min); a wrong PIN or password is a
// failed check, and the tenth in a row is answered and then locks the vault (`vault.locking{reason: "owner_check"}`).
// A check that passes rotates the blob, moves the deadline and ends the hold.
extension FakeVaultService {
    static let typeOwnerCheck = "vault.owner-check"
    /// The failed checks in a row that lock the vault (`OwnerCheckLockAfter`).
    static let checkLockAfter = 10
    /// Password failures in a row before its backoff (`BackoffAfter`).
    static let passwordBackoffAfter = 5
    static let maxHoldOff: TimeInterval = 30 * 86_400
    /// The types the app may send while gated (vettid-vault `holdAllows`, the app's list).
    static let gatedAllowed: Set<String> = [
        typeOwnerCheck, "vault.status", "vault.lock", "credential.utk.get", "credential.get", "credential.ack", "credential.version",
        "credential.lock", "call.end", "push.register", "push.confirm", "push.unregister", "location.share.stop",
    ]

    /// What the vault received in one owner check.
    public struct OwnerCheckSeen: Sendable {
        public let pin: String
        public let password: String
        public let hold: Bool?
        public let holdOffUntil: String?
        /// The blob sent with it.
        public let credential: String?
    }

    // MARK: - Switches and what was seen

    /// The vault's clock (the real one moved ahead by ``advanceVaultClock(_:)``).
    var vaultNow: Date { Date().addingTimeInterval(vaultClockAhead) }

    public var ownerChecks: [OwnerCheckSeen] { locked { ownerChecksValue } }
    /// Consecutive failed checks (§3.6.4).
    public var ownerCheckFailures: Int { locked { checkFailures } }
    /// The owner check's deadline on the vault's clock; nil before the first credential.
    public var ownerCheckDeadline: Date? { locked { checkDeadline } }
    /// The credential version the vault holds (it rotates at each passed check).
    public var vaultCredentialVersion: Int64 { locked { credentialVersion } }
    /// Whether the hold is off (§3.6.7).
    public var holdIsOff: Bool { locked { holdOffValue } }

    /// Whether the next passed checks say the member's presence was recorded (§11.14.5).
    public var presentRecorded: Bool {
        get { locked { presentRecordedValue } }
        set { locked { presentRecordedValue = newValue } }
    }

    /// Something arrived for the owner while the vault is gated (§3.6.3): counted, and `vault.held` sent with the counts.
    public func heldArrived(messages: Int = 0, requests: Int = 0, calls: Int = 0, other: Int = 0) {
        locked {
            waitingCounts = zip(waitingCounts, [messages, requests, calls, other]).map(+)
            guard vaultOpen, !checkGate.isEmpty else { return }
            try? sendHeld()
        }
    }

    /// The vault's owner-check state at its clock: "ok", "due" or "held" (`ownerCheckState`). Callers hold ``cond``.
    func checkState() -> String {
        guard hasCredential, let deadline = checkDeadline, vaultNow >= deadline else { return "ok" }
        return holdOn() ? "held" : "due"
    }

    /// `HoldOn`: the hold, back on by itself at `hold_off_until`. Callers hold ``cond``.
    private func holdOn() -> Bool { !holdOffValue || holdOffUntilValue.map { vaultNow >= $0 } == true }

    /// The clock starts, or starts again (a passed check). Callers hold ``cond``.
    func startCheckClock() {
        let now = vaultNow
        checkLastAt = now
        checkDeadline = now.addingTimeInterval(checkInterval)
        checkFailures = 0
    }

    /// `ownerCheckTick`: a hold turned off comes back on at its end date; the gate begins (counts from zero, `vault.held`
    /// at once) or ends. Callers hold ``cond``.
    func ownerCheckTick() throws {
        if holdOffValue, let until = holdOffUntilValue, vaultNow >= until {
            holdOffValue = false
            holdOffUntilValue = nil
        }
        let state = checkState()
        let gate = state == "ok" ? "" : state
        guard gate != checkGate else { return }
        if checkGate.isEmpty { waitingCounts = [0, 0, 0, 0] }
        checkGate = gate
        if !gate.isEmpty { try sendHeld() }
    }

    /// `holdAllows` for the app. Callers hold ``cond``.
    func holdAllows(_ type: String) -> Bool { checkState() == "ok" || Self.gatedAllowed.contains(type) }

    private func sendHeld() throws {
        let w = waitingCounts
        try reply("vault.held", #"{"deadline":"\#(checkDeadline.map(Timestamps.formatMillis) ?? "")","waiting":{"messages":\#(w[0]),"requests":\#(w[1]),"calls":\#(w[2]),"other":\#(w[3])}}"#)
    }

    /// The credential blob of [version] of the credential of [generation] (a reset makes a new one; opaque to the app).
    static func blob(_ version: Int64, generation: Int = 0) -> String {
        if generation > 0 { return Base64s.encodeStd(Array("blob-g\(generation)-\(version)".utf8)) }
        return version == 1 ? "AQID" : Base64s.encodeStd(Array("blob-\(version)".utf8))
    }

    // MARK: - vault.status and the settings

    /// `vault.status` (§10.2) with `owner_check` (§3.6) and `recovery` (§11.14.11). Callers hold ``cond``.
    func status(_ m: Inner) throws {
        let state = checkState()
        var oc = #"{"state":"\#(state)""#
        if let d = checkDeadline { oc += #","deadline":"\#(Timestamps.formatMillis(d))""# }
        oc += #","interval_seconds":\#(Int(checkInterval)),"failures":\#(checkFailures),"hold":\#(!holdOffValue)"#
        if holdOffValue, let u = holdOffUntilValue { oc += #","hold_off_until":"\#(Timestamps.formatMillis(u))""# }
        if state != "ok" {
            let w = waitingCounts
            oc += #","waiting":{"messages":\#(w[0]),"requests":\#(w[1]),"calls":\#(w[2]),"other":\#(w[3])}"#
        }
        oc += "}"
        let scale = timeScaleValue.map { ",\"time_scale\":\($0)" } ?? ""
        try reply(m.type, #"{"vault_id":"\#(vaultID)","state_seq":\#(stateSeq),"header_seq":\#(headerSeq),"provisional":\#(!confirmedValue),"devices":1,"connections":0,"owner_check":\#(oc),"recovery":{"state":"armed","attempts":{"used":0,"of":10},"counter":"\#(recoveryCounterValue)"}\#(scale)}"#, re: m.id)
    }

    /// `settingsOwnerCheck`: a shorter interval moves the deadline earlier at once; the hold turned on. Callers hold
    /// ``cond``.
    func ownerCheckSettings(_ set: JsonObject) throws {
        if let secs = try set.optUint("owner_check.interval_seconds", min: 3600, max: 86_400) {
            let interval = TimeInterval(secs)
            if interval < checkInterval, let last = checkLastAt, let d = checkDeadline, last.addingTimeInterval(interval) < d {
                checkDeadline = last.addingTimeInterval(interval)
            }
            checkInterval = interval
        }
        if case .bool(_, true)? = set["owner_check.hold"] {
            holdOffValue = false
            holdOffUntilValue = nil
        }
        try ownerCheckTick()
    }

    // MARK: - vault.owner-check

    /// Steps 2–8 of §3.6.1, in vettid-vault's order. Callers hold ``cond``.
    func ownerCheck(_ m: Inner, _ body: JsonObject) throws {
        let utk = try body.string("utk_id")
        guard let ltk = utks.removeValue(forKey: utk) else { return try reply(m.type, "{}", re: m.id, error: "utk_invalid") }
        let pt = try CredentialSeal.openPayload(ltk: ltk, vaultID: vaultID, utkID: utk, type: m.type, innerID: m.id, sealed: try body.base64("sealed"))
        let p = try StrictJson.parseObject(pt)
        let pin = (try? p.string("pin")) ?? ""
        let password = (try? p.string("password")) ?? ""
        let hold = p.has("hold") ? try p.bool("hold") : nil
        let until = try p.optString("hold_off_until")
        let sentBlob = try body.optString("credential")
        ownerChecksValue.append(OwnerCheckSeen(pin: pin, password: password, hold: hold, holdOffUntil: until, credential: sentBlob))
        let now = vaultNow
        // holdChange: answered before the PIN is tried, so not a failed check.
        var untilDate: Date?
        if let until {
            guard hold == false, let t = Self.rfc3339(until), t > now, t <= now.addingTimeInterval(Self.maxHoldOff) else {
                return try reply(m.type, "{}", re: m.id, error: "bad_request")
            }
            untilDate = t
        }
        guard try checkSecrets(m, pin: pin, password: password, blob: sentBlob) else { return }
        // Step 8: the CEK rotates, the check is recorded, the hold change applied and a hold ended.
        credentialVersion += 1
        startCheckClock()
        if let hold {
            holdOffValue = !hold
            holdOffUntilValue = hold ? nil : untilDate
        }
        checkGate = ""
        waitingCounts = [0, 0, 0, 0]
        var answer = #"{"credential":"\#(currentBlob)","version":\#(credentialVersion),"utks":\#(try issueUTKs(2)),"deadline":"\#(checkDeadline.map(Timestamps.formatMillis) ?? "")","interval_seconds":\#(Int(checkInterval)),"hold":\#(!holdOffValue)"#
        if holdOffValue, let u = holdOffUntilValue { answer += #","hold_off_until":"\#(Timestamps.formatMillis(u))""# }
        answer += #","recovery":{"state":"armed","present_recorded":\#(presentRecordedValue)}}"#
        try reply(m.type, answer, re: m.id)
    }

    /// Steps 3–7 of §3.6.1, as every holder operation checked like an owner check runs them (`openChecked`): the blob,
    /// the PIN under the §11.8 backoff (the unlock's), then the password under its own; a wrong PIN or password is a
    /// failed check. False when refused (the refusal is answered). Callers hold ``cond``.
    func checkSecrets(_ m: Inner, pin: String, password: String, blob: String?) throws -> Bool {
        let now = vaultNow
        // Step 3: the blob (the holder's own retry, or a clone).
        guard try checkBlob(m, blob) else { return false }
        // Steps 4–5: the PIN.
        if let b = backoffUntil, now < b {
            try backoff(m, b.timeIntervalSince(now))
            return false
        }
        guard pin == vaultPin else {
            pinFailures += 1
            headerSeq += 1
            let wait = pinFailures < 3 ? 0 : Self.backoffDelays[min(pinFailures - 3, Self.backoffDelays.count - 1)]
            backoffUntil = wait > 0 ? now.addingTimeInterval(wait) : nil
            try failedCheck(m, "bad_pin")
            return false
        }
        pinFailures = 0
        backoffUntil = nil
        // Steps 6–7: the password.
        if let b = passwordNotBefore, now < b {
            try backoff(m, b.timeIntervalSince(now))
            return false
        }
        guard password == vaultPassword else {
            passwordFailures += 1
            let n = passwordFailures - Self.passwordBackoffAfter
            if n >= 0 { passwordNotBefore = now.addingTimeInterval(Self.backoffDelays[min(n, Self.backoffDelays.count - 1)]) }
            try failedCheck(m, "bad_password")
            return false
        }
        passwordFailures = 0
        passwordNotBefore = nil
        return true
    }

    private func backoff(_ m: Inner, _ left: TimeInterval) throws {
        try reply(m.type, #"{"retry_after":\#(max(Int(left.rounded(.up)), 1))}"#, re: m.id, error: "backoff")
    }

    /// `ownerCheckFailed`: counted; the tenth in a row is answered, then the vault locks. Callers hold ``cond``.
    private func failedCheck(_ m: Inner, _ code: String) throws {
        checkFailures += 1
        try reply(m.type, "{}", re: m.id, error: code)
        if checkFailures >= Self.checkLockAfter {
            try reply("vault.locking", #"{"reason":"owner_check"}"#)
            close()
        }
    }

    static func rfc3339(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// swiftlint:enable line_length
#endif
