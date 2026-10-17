import Foundation

/// The password rules of VAULT-MESSAGING 0.33.0 §11.14.7 (release R) on the phone, so that the member learns while
/// typing what the vault would answer (`weak_password{reason}`). A port of vettid-vault's `vms/recovery/password.go`
/// through vettid-android's `PasswordRules` (the five rules in order, and the zxcvbn-like estimator with the same word
/// lists, in `Resources/passwords/`), run with a threshold a little above the vault's, so that a password the app
/// accepts is rarely refused. The vault's verdict is final. No network.
public enum PasswordRules {
    public static let minChars = 12
    /// The vault's floor (`GuessabilityFloor`, 10^10 guesses).
    public static let vaultFloor = 1e10
    /// The app's: a little above the vault's (§11.14.7).
    public static let appFloor = 2e10

    /// `weak_password` reasons, as the vault names them.
    public static let short = "short"
    public static let repeated = "repeated"
    public static let common = "common"
    public static let sameAsPin = "same_as_pin"
    public static let guessable = "guessable"

    private static let commonList = load("common-passwords")
    private static let words = load("estimator-words")

    /// A word list: each non-comment, non-blank line's rank (1-based, first occurrence wins).
    private static func load(_ name: String) -> [String: Int] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "passwords"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("missing password list \(name)")
            return [:]
        }
        var m: [String: Int] = [:]
        var rank = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let w = line.trimmingCharacters(in: CharacterSet(charactersIn: "\u{00}"..."\u{20}"))
            if w.isEmpty || w.hasPrefix("#") { continue }
            rank += 1
            if m[w] == nil { m[w] = rank }
        }
        return m
    }

    /// The first rule [password] breaks, in the vault's order, or nil: at least 12 characters (code points), not one
    /// character repeated, not on the common list (ASCII letters lowered), not the [pin], at least [floor] guesses.
    /// [password] is normalized to NFC first, as the vault does.
    public static func check(_ password: String, pin: String?, floor: Double = appFloor) -> String? {
        let pw = Passwords.nfc(password)
        let cps = scalars(pw)
        if cps.count < minChars { return short }
        if cps.allSatisfy({ $0 == cps[0] }) { return repeated }
        if commonList[lowerASCII(pw)] != nil { return common }
        if let pin, !pin.isEmpty, cps == scalars(pin) { return sameAsPin }
        if guesses(pw) < floor { return guessable }
        return nil
    }

    // MARK: - The estimator (vettid-vault's, rule for rule)

    private static let minGuessesSingle = 10.0
    private static let minGuessesMulti = 50.0
    private static let bruteforceCard = 10.0
    private static let maxEstimateChars = 128
    private static let maxParts = 12

    private static let leet: [UInt32: UInt32] = {
        let pairs: [(Character, Character)] = [
            ("4", "a"), ("@", "a"), ("8", "b"), ("(", "c"), ("3", "e"), ("6", "g"), ("1", "i"), ("!", "i"), ("|", "i"),
            ("0", "o"), ("$", "s"), ("5", "s"), ("7", "t"), ("+", "t"), ("2", "z"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.unicodeScalars.first!.value, $0.1.unicodeScalars.first!.value) })
    }()

    private static let keyboardRows = [
        "`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./", "1qaz2wsx3edc4rfv5tgb6yhn7ujm8ik,9ol.0p;/",
    ]

    private static func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }

    private static func str(_ cps: some Collection<UInt32>) -> String {
        var s = String.UnicodeScalarView()
        for c in cps { if let u = Unicode.Scalar(c) { s.append(u) } }
        return String(s)
    }

    /// Lower case by the root locale's full mapping (Kotlin's `lowercase(Locale.ROOT)`).
    private static func lower(_ s: String) -> String { s.lowercased() }

    private static func lowerASCII(_ s: String) -> String {
        str(scalars(s).map { (0x41...0x5A).contains($0) ? $0 + 32 : $0 })
    }

    private static func reverse(_ s: String) -> String { str(scalars(s).reversed()) }

    private static func isUpper(_ c: UInt32) -> Bool { Unicode.Scalar(c)?.properties.isUppercase ?? false }

    /// A decimal digit of any script (general category Nd), as Java's `Character.isDigit`.
    private static func isDigit(_ c: UInt32) -> Bool { Unicode.Scalar(c)?.properties.generalCategory == .decimalNumber }

    /// The simple lower-case mapping of one code point (Java's `Character.toLowerCase(int)`).
    private static func toLower(_ c: UInt32) -> UInt32 {
        guard let u = Unicode.Scalar(c) else { return c }
        let m = u.properties.lowercaseMapping.unicodeScalars
        return m.count == 1 ? m.first!.value : c
    }

    private static func dictGuesses(_ sub: [UInt32]) -> Double {
        var best = Double.infinity
        func tryWord(_ s: String, _ factor: Double) {
            if let r = commonList[s] { best = min(best, Double(r) * factor) }
            if let r = words[s] { best = min(best, Double(r) * factor) }
        }
        let orig = str(sub)
        let lowered = lower(orig)
        var upper = 1.0
        if lowered != orig {
            upper = 2.0
            let rest = str(sub.dropFirst())
            let capitalized = isUpper(sub[0]) && lower(rest) == rest
            if !capitalized, orig.uppercased() != orig { upper = pow(2.0, Double(sub.filter(isUpper).count)) }
        }
        tryWord(lowered, upper)
        tryWord(reverse(lowered), 2 * upper)
        var subs = 0
        let ul = scalars(lowered).map { c -> UInt32 in
            if let l = leet[c] {
                subs += 1
                return l
            }
            return c
        }
        if subs > 0 {
            let f = upper * pow(2.0, Double(subs))
            tryWord(str(ul), f)
            tryWord(reverse(str(ul)), 2 * f)
        }
        return best
    }

    private static func sequenceGuesses(_ cps: [UInt32]) -> Double {
        if cps.count < 3 { return .infinity }
        let d = Int64(cps[1]) - Int64(cps[0])
        if d == 0 || d > 2 || d < -2 { return .infinity }
        for i in 2..<cps.count where Int64(cps[i]) - Int64(cps[i - 1]) != d { return .infinity }
        let first = toLower(cps[0])
        let ascii = { (c: Character) in c.unicodeScalars.first!.value }
        var base: Double
        if [ascii("a"), ascii("z"), ascii("0"), ascii("1"), ascii("9")].contains(first) {
            base = 4
        } else if isDigit(first) {
            base = 10
        } else {
            base = 26
        }
        if d < 0 { base *= 2 }
        return base * Double(cps.count)
    }

    private static func keyboardGuesses(_ cps: [UInt32]) -> Double {
        if cps.count < 4 { return .infinity }
        let s = lower(str(cps))
        for row in keyboardRows where row.contains(s) || reverse(row).contains(s) {
            return 94 * 4.6 * Double(cps.count)
        }
        return .infinity
    }

    private static func repeatGuesses(_ cps: [UInt32]) -> Double {
        let n = cps.count
        for u in stride(from: 1, through: n / 2, by: 1) where n % u == 0 {
            var ok = true
            var i = u
            while i < n, ok {
                ok = cps[i] == cps[i - u]
                i += 1
            }
            if ok { return guesses(str(cps[0..<u])) * Double(n / u) }
        }
        return .infinity
    }

    private static func dateGuesses(_ cps: [UInt32]) -> Double {
        if cps.count < 4 || cps.count > 10 { return .infinity }
        var digits = 0
        for c in cps {
            if isDigit(c) {
                digits += 1
            } else if c != 0x2F, c != 0x2D, c != 0x2E { // / - .
                return .infinity
            }
        }
        if digits < 4 || digits > 8 { return .infinity }
        return digits == 4 ? 119 : 365 * 119
    }

    /// The character classes of the brute-force estimate and their sizes: a-z, A-Z, 0-9, other ASCII, anything else.
    private static let classCards: [Double] = [26, 26, 10, 33, 100]

    private static func charClass(_ c: UInt32) -> Int {
        switch c {
        case 0x61...0x7A: 0
        case 0x41...0x5A: 1
        case 0x30...0x39: 2
        case ..<128: 3
        default: 4
        }
    }

    private static func bruteforce(_ cps: [UInt32]) -> Double {
        let classes = Set(cps.map(charClass))
        let card = classes.sorted().reduce(0.0) { $0 + classCards[$1] }
        return pow(max(card, bruteforceCard), Double(cps.count))
    }

    private static func matchGuesses(_ sub: [UInt32]) -> Double {
        var g = bruteforce(sub)
        for m in [dictGuesses(sub), sequenceGuesses(sub), keyboardGuesses(sub), dateGuesses(sub)] { g = min(g, m) }
        if sub.count >= 2 { g = min(g, repeatGuesses(sub)) }
        return max(g, sub.count == 1 ? minGuessesSingle : minGuessesMulti)
    }

    /// How many guesses a well-informed attacker needs for [password] (the vault's model): the cheapest split into at
    /// most 12 parts, each part's cheapest match.
    public static func guesses(_ password: String) -> Double {
        let cps = scalars(password)
        let n = cps.count
        if n == 0 { return 0 }
        if n > maxEstimateChars { return .infinity }
        var best = [[Double]](repeating: [Double](repeating: .infinity, count: maxParts + 1), count: n + 1)
        best[0][0] = 1
        for j in 1...n {
            for i in 0..<j {
                let g = matchGuesses(Array(cps[i..<j]))
                for k in 1...maxParts {
                    let p = best[i][k - 1]
                    if !p.isInfinite { best[j][k] = min(best[j][k], p * g) }
                }
            }
        }
        var out = Double.infinity
        var fact = 1.0
        for k in 1...maxParts {
            fact *= Double(k)
            let g = best[n][k]
            if !g.isInfinite { out = min(out, fact * g + pow(10000.0, Double(k - 1))) }
        }
        return out
    }
}
