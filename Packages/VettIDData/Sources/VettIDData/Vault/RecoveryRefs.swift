import Foundation
import VettIDCrypto

/// The `ref`s of release R's recovery entries as the vault writes them (VAULT-MESSAGING 0.50.0 §10.9, §11.14.11), read for
/// the event titles (IOS-PLAN §4.1, ANDROID-PLAN §4 "Event titles"). Every reader returns nil for a `ref` that does not
/// read, so that the title falls back to its generic form. Mirrors vettid-android `RecoveryRefs`.
public enum RecoveryRefs {
    /// Recovery attempts per generation (§11.14.4).
    public static let attempts = 10

    public static let kindAttempt = "recovery.attempt"
    public static let kindClosed = "recovery.generation_closed"
    public static let kindOpen = "recovery.open"
    /// A next generation only already closed (the harmless case; hidden in History).
    public static let reasonStale = "stale"
    /// (VAULT-MESSAGING 0.50.0, owner decision of 2026-10-20) A next generation that already showed used attempts: a host
    /// may have served an older copy of the recovery record. Shown, and an urgent recovery alarm.
    public static let reasonRollback = "rollback"

    /// The open outcomes that counted an attempt; `busy` and `wrong_again` did not, so no attempt shows them.
    public static let counted: Set<String> = ["wrong", "attempt_lost", "quiet", "wait", "exhausted", "closed"]
    /// How far an open's time may be from its attempt's (the enclave's clock against the counter's).
    public static let window: TimeInterval = 10 * 60
    /// The longest attempting phone's name shown, in code points.
    static let maxNameCodePoints = 64

    /// `recovery.attempt`: `<generation>/<n>/<outcome>/counter`, the outcome `success` or `not_success`.
    public struct Attempt: Equatable, Sendable {
        public var generation: Int64
        public var n: Int
        public var success: Bool

        public init(generation: Int64, n: Int, success: Bool) {
            self.generation = generation
            self.n = n
            self.success = success
        }
    }

    public static func attempt(_ ref: String?) -> Attempt? {
        guard let p = parts(ref), p.count == 4, p[3] == "counter" else { return nil }
        guard let g = Int64(p[0]), g >= 1, let n = Int(p[1]), (1...attempts).contains(n) else { return nil }
        switch p[2] {
        case "success": return Attempt(generation: g, n: n, success: true)
        case "not_success": return Attempt(generation: g, n: n, success: false)
        default: return nil
        }
    }

    /// `recovery.attempts_used`: `<generation>/<used>`; the number used.
    public static func attemptsUsed(_ ref: String?) -> Int? {
        guard let p = parts(ref), p.count == 2, let g = Int64(p[0]), g >= 1, let n = Int(p[1]) else { return nil }
        return (1...attempts).contains(n) ? n : nil
    }

    /// `recovery.generation_closed`: `<generation>/<reason>`, with `/unconfirmed` after `delete` when the counter did not
    /// confirm the close. [reason] is as written (`pin`, `password`, `reset`, `backup_off`, `exhausted`, `delete`,
    /// `stale`, `rollback`, or one a newer vault adds).
    public struct Closure: Equatable, Sendable {
        public var generation: Int64
        public var reason: String
        public var unconfirmed: Bool

        public init(generation: Int64, reason: String, unconfirmed: Bool) {
            self.generation = generation
            self.reason = reason
            self.unconfirmed = unconfirmed
        }
    }

    public static func closure(_ ref: String?) -> Closure? {
        guard let p = parts(ref) else { return nil }
        let unconfirmed = p.count == 3 && p[2] == "unconfirmed"
        guard p.count == 2 || unconfirmed, let g = Int64(p[0]), g >= 1, !p[1].isEmpty else { return nil }
        return Closure(generation: g, reason: p[1], unconfirmed: unconfirmed)
    }

    /// Whether [kind] with [ref] is a `rollback` closure.
    public static func rollback(_ kind: String, ref: String?) -> Bool { kind == kindClosed && closure(ref)?.reason == reasonRollback }

    /// `recovery.open`: `<recovery_id>/<outcome>`, or (VAULT-MESSAGING 0.50.0) `<recovery_id>/<outcome>/<name>`, the
    /// details a host can drop (§11.14.11). [phoneName] is the attempting phone's **self-reported** name (base64url in the
    /// `ref`), cleaned for display; nil when the `ref` has none, it does not decode, or nothing is left. It is shown only
    /// as "From a phone that calls itself “<name>”." and never affects urgency, a notification or any decision.
    public struct Open: Equatable, Sendable {
        public var recoveryID: String
        public var outcome: String
        public var phoneName: String?

        public init(recoveryID: String, outcome: String, phoneName: String? = nil) {
            self.recoveryID = recoveryID
            self.outcome = outcome
            self.phoneName = phoneName
        }
    }

    public static func open(_ ref: String?) -> Open? {
        guard let p = parts(ref), p.count == 2 || p.count == 3, !p[0].isEmpty, !p[1].isEmpty else { return nil }
        return Open(recoveryID: p[0], outcome: p[1], phoneName: p.count == 3 ? phoneName(p[2]) : nil)
    }

    /// The name's UTF-8 from base64url (no padding), cleaned for display (IOS-PLAN §4.1): without control characters,
    /// Unicode format characters (category Cf: the direction controls, ALM, zero-width characters, U+FEFF), the line and
    /// paragraph separators, U+FFFD and the quotation marks “ ” " (so that a name cannot close the quote and fake a
    /// sentence after it); trimmed, and at most 64 code points (a code point is never split). Nil if nothing is left.
    public static func phoneName(_ b64: String) -> String? {
        guard let bytes = try? Base64s.decodeRawUrl(b64) else { return nil }
        // An invalid sequence becomes U+FFFD, which the cleaning removes (as vettid-android's decoding does).
        return cleanName(String(decoding: bytes, as: UTF8.self)) // swiftlint:disable:this optional_data_string_conversion
    }

    /// The cleaning of ``phoneName(_:)`` on decoded text.
    public static func cleanName(_ raw: String) -> String? {
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: raw.unicodeScalars.filter { !hidden($0) })
        let trimmed = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        var capped = String.UnicodeScalarView()
        capped.append(contentsOf: trimmed.unicodeScalars.prefix(maxNameCodePoints))
        let out = String(capped).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    private static let quotes: Set<UInt32> = [0x201C, 0x201D, 0x22]

    private static func hidden(_ s: Unicode.Scalar) -> Bool {
        let cat = s.properties.generalCategory
        return cat == .control || cat == .format || cat == .lineSeparator || cat == .paragraphSeparator
            || s.value == 0xFFFD || quotes.contains(s.value)
    }

    /// The outcome of each `not_success` attempt among [entries] (IOS-PLAN §4.1 "An attempt's outcome"): taken in order of
    /// `at`, the nearest `recovery.open` within ``window`` whose outcome counted an attempt, each open used once; an attempt
    /// written again as `success` is not matched. The result maps an attempt's `seq` to its outcome; one without a match is
    /// absent.
    public static func outcomes(_ entries: [AuditRecord]) -> [Int64: String] { matches(entries).mapValues(\.outcome) }

    /// As ``outcomes(_:)``, with the whole matched open (its outcome and the phone's self-reported name).
    public static func matches(_ entries: [AuditRecord]) -> [Int64: Open] {
        let done = succeeded(entries)
        let attempts = entries.compactMap { e -> (Int64, Date)? in
            guard e.kind == kindAttempt, let at = e.at, let a = attempt(e.entry.ref), !a.success,
                  !done.contains(Key(generation: a.generation, n: a.n)) else { return nil }
            return (e.seq, at)
        }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let opens = entries.compactMap { e -> Timed? in
            guard e.kind == kindOpen, let at = e.at, let o = open(e.entry.ref), counted.contains(o.outcome) else { return nil }
            return Timed(seq: e.seq, at: at, open: o)
        }.sorted { $0.at != $1.at ? $0.at < $1.at : $0.seq < $1.seq }
        var used = Set<Int64>()
        var out: [Int64: Open] = [:]
        for (seq, at) in attempts {
            let best = opens.filter { !used.contains($0.seq) }
                .map { ($0, abs($0.at.timeIntervalSince(at))) }
                .filter { $0.1 <= window }
                .min { $0.1 < $1.1 }
            guard let (o, _) = best else { continue }
            used.insert(o.seq)
            out[seq] = o.open
        }
        return out
    }

    /// Whether [entry], an attempt first written as `not_success`, was written again as `success` among [entries] (the
    /// vault rewrites an attempt the counter later shows succeeded, §11.14.11): History then says "Later successful.".
    public static func laterSuccessful(_ entry: AuditRecord, in entries: [AuditRecord]) -> Bool {
        guard entry.kind == kindAttempt, let a = attempt(entry.entry.ref), !a.success else { return false }
        return succeeded(entries).contains(Key(generation: a.generation, n: a.n))
    }

    /// A `recovery.open` entry that counted an attempt, with its time.
    private struct Timed {
        var seq: Int64
        var at: Date
        var open: Open
    }

    private struct Key: Hashable {
        var generation: Int64
        var n: Int
    }

    private static func succeeded(_ entries: [AuditRecord]) -> Set<Key> {
        Set(entries.filter { $0.kind == kindAttempt }.compactMap { attempt($0.entry.ref) }.filter(\.success)
            .map { Key(generation: $0.generation, n: $0.n) })
    }

    /// The `/`-separated parts of [ref] (empty parts kept); nil without one.
    private static func parts(_ ref: String?) -> [String]? {
        ref.map { $0.split(separator: "/", omittingEmptySubsequences: false).map(String.init) }
    }
}
