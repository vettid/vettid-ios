import Foundation
import VettIDData

/// The one stored form of each value kind (VAULT-MESSAGING §10.7 "Canonical forms" and "Phone values", 0.55.0; IOS-PLAN
/// §4.8). Every writer of `item.put` applies it to a field the member edited or created (``draft(_:original:region:)``);
/// a field the member did not touch is sent exactly as stored, so a secret value never revealed is never rewritten, and an
/// older value is stored in this form only when its field is next edited and saved. Case changes map ASCII `A`-`Z` and
/// `a`-`z` only; white space is the Unicode `White_Space` property. The vault does not normalise: the app checks the result
/// (``ItemChecks``) before it saves.
public enum CanonicalForms {
    // MARK: - Text helpers

    /// [s] without its leading and trailing white space (Unicode `White_Space`).
    public static func trim(_ s: String) -> String {
        var scalars = Substring(s).unicodeScalars
        while let f = scalars.first, f.properties.isWhitespace { scalars.removeFirst() }
        while let l = scalars.last, l.properties.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }

    /// [s] trimmed, with every run of white space inside it one space.
    public static func collapse(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var gap = false
        for c in trim(s).unicodeScalars {
            if c.properties.isWhitespace {
                gap = true
            } else {
                if gap { out.append(" ") }
                gap = false
                out.append(c)
            }
        }
        return String(out)
    }

    /// [s] with the ASCII letters of [from] mapped by [shift] (ASCII only: other characters stay as typed).
    private static func ascii(_ s: String, _ from: ClosedRange<Unicode.Scalar>, _ shift: (UInt32) -> UInt32) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { from.contains($0) ? Unicode.Scalar(shift($0.value)) ?? $0 : $0 }))
    }

    public static func lower(_ s: String) -> String { ascii(s, "A"..."Z") { $0 + 32 } }

    public static func upper(_ s: String) -> String { ascii(s, "a"..."z") { $0 - 32 } }

    // MARK: - The kinds

    /// `number` (0.55.2): the text as typed, trimmed, with a single leading `+` dropped; leading zeros, `-0` and trailing
    /// fractional zeros are kept (members store codes in Number). The result must still match the grammar, which refuses
    /// `5.`, `.5` and `++5` as before.
    public static func number(_ typed: String) -> String {
        let t = trim(typed)
        return t.hasPrefix("+") ? String(t.dropFirst()) : t
    }

    /// `date`: `YYYY-MM` when the field is a month and year ([month]: its template carries `"format": "month"`, or it holds
    /// `YYYY-MM` already), else the form typed; the app never invents a day.
    public static func date(_ typed: String, month: Bool) -> String {
        month && typed.utf8.count == 10 ? String(typed.prefix(7)) : typed
    }

    /// `email`: trimmed, the domain (after the last `@`) lower-cased, the local part as typed.
    public static func email(_ typed: String) -> String {
        let t = trim(typed)
        guard let at = t.lastIndex(of: "@") else { return t }
        return t[...at] + lower(String(t[t.index(after: at)...]))
    }

    /// `url`: trimmed; a text that starts with `scheme://` keeps its scheme and host lower-cased; `mailto:`, `tel:` and
    /// `sms:` keep their form with the scheme lower-cased; anything else gets `https://` in front (and so its host lower-cased). The rest as typed.
    public static func url(_ typed: String) -> String {
        let t = trim(typed)
        guard !t.isEmpty else { return t }
        if let r = t.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) {
            let rest = t[r.upperBound...]
            let end = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
            let authority = rest[..<end]
            let userinfo = authority.lastIndex(of: "@").map { authority[...$0] } ?? ""
            let hostPort = authority.dropFirst(userinfo.count)
            let hostEnd: String.Index
            if hostPort.first == "[" {
                hostEnd = hostPort.firstIndex(of: "]").map { hostPort.index(after: $0) } ?? hostPort.endIndex
            } else {
                hostEnd = hostPort.firstIndex(of: ":") ?? hostPort.endIndex
            }
            return lower(String(t[r])) + userinfo + lower(String(hostPort[..<hostEnd])) + hostPort[hostEnd...] + rest[end...]
        }
        let lowered = lower(t)
        for scheme in ["mailto:", "tel:", "sms:"] where lowered.hasPrefix(scheme) {
            return scheme + t.dropFirst(scheme.count)
        }
        return url("https://" + t)
    }

    /// The label as a path segment of an `otpauth://` URI: its UTF-8 bytes, every one but `A-Za-z0-9-._~` as `%XX` in
    /// upper-case hex.
    public static func percentEncoded(_ label: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        return label.utf8.map { unreserved.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    /// `otp`: a bare secret becomes `otpauth://totp/<label>?secret=<SECRET>&algorithm=SHA1&digits=6&period=30` (the label
    /// [label] percent-encoded, the secret upper-case base32 without spaces or padding); a URI keeps its parameters and has
    /// its `secret` canonical. A secret that is not a base32 secret is left as typed (the check refuses it).
    public static func otp(_ typed: String, label: String) -> String {
        let t = trim(typed)
        if lower(t).hasPrefix("otpauth:") { return otpURI(t) }
        let secret = upper(String(String.UnicodeScalarView(t.unicodeScalars.filter { !$0.properties.isWhitespace })))
        let bare = secret.replacingOccurrences(of: "=+$", with: "", options: .regularExpression)
        guard ItemChecks.valueProblems(FieldKinds.otp, .text(bare)).isEmpty, !bare.isEmpty else { return typed }
        return "otpauth://totp/\(percentEncoded(label))?secret=\(bare)&algorithm=SHA1&digits=6&period=30"
    }

    private static func otpURI(_ uri: String) -> String {
        let head = lower(uri).hasPrefix("otpauth://") ? "otpauth://" + uri.dropFirst("otpauth://".count) : uri
        guard let q = head.firstIndex(of: "?") else { return head }
        let params = head[head.index(after: q)...].split(separator: "&", omittingEmptySubsequences: false).map { p -> String in
            // §10.7: other parameters stay as given and only the secret's value is canonical (its name as typed).
            guard lower(String(p)).hasPrefix("secret=") else { return String(p) }
            let value = upper(String(p.dropFirst("secret=".count)))
            let clean = String(String.UnicodeScalarView(value.unicodeScalars.filter { !$0.properties.isWhitespace && $0 != "=" }))
            return String(p.prefix("secret=".count)) + clean
        }
        return head[...q] + params.joined(separator: "&")
    }

    /// `address`: the street, the second line, the city and the region trimmed with inner white space collapsed to single
    /// spaces, the postal code too and upper-cased, the country trimmed and upper-cased; a member empty after trimming is left
    /// out (it is empty).
    public static func address(_ a: AddressValue) -> AddressValue {
        AddressValue(
            street: collapse(a.street), street2: collapse(a.street2), city: collapse(a.city), region: collapse(a.region),
            postalCode: upper(collapse(a.postalCode)), country: upper(trim(a.country))
        )
    }

    // MARK: - Fields and items

    /// The field as saved: [f], when the member edited or created it, in the canonical form of its kind; a field that is not
    /// ([touched] false) exactly as stored. A kept value (a secret or critical item's, never revealed) is never rewritten.
    public static func field(_ f: DraftField, touched: Bool, region: String?) -> DraftField {
        guard touched else { return f }
        var c = f
        c.label = trim(f.label)
        guard !f.kept else { return c }
        if f.kind == FieldKinds.address {
            c.address = address(f.address)
        } else {
            c.text = text(f, label: c.label, region: region)
        }
        return c
    }

    /// The canonical form of a field's text by its kind.
    private static func text(_ f: DraftField, label: String, region: String?) -> String {
        switch f.kind {
        case FieldKinds.text: trim(f.text)
        case FieldKinds.number: number(f.text)
        case FieldKinds.date: date(f.text, month: f.monthYear)
        case FieldKinds.email: email(f.text)
        case FieldKinds.url: url(f.text)
        case FieldKinds.phone: PhoneInput.stored(f.text, region: region)
        case FieldKinds.otp: otp(f.text, label: label)
        default: f.text
        }
    }

    /// The draft as `item.put` saves it: its name trimmed when the member edited it, each field it edited or created in
    /// its canonical form (a field is edited when it differs from the same field of [original], the draft as it was loaded;
    /// without an [original] every field is new), the notes as typed.
    public static func draft(_ d: ItemDraft, original: ItemDraft?, region: String?) -> ItemDraft {
        var out = d
        if original?.name != d.name { out.name = trim(d.name) }
        let before = Dictionary((original?.fields ?? []).compactMap { f in f.fieldID.map { ($0, f) } }, uniquingKeysWith: { a, _ in a })
        out.fields = d.fields.map { f in
            let touched = f.fieldID.map { before[$0] != f } ?? true
            return field(f, touched: touched, region: region)
        }
        return out
    }
}
