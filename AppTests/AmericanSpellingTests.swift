import Foundation
import Testing

/// Every text the member sees is written in American English (owner decision of 2026-11-05). This guard reads every
/// string catalog of the repository (every `*.xcstrings` under `Packages/` and `App/`) and fails when a value, in any
/// language entry, matches a common British spelling: -our (colour, favourite), -ise/-isation (organise, recognise),
/// -yse, -tre (centre, metre), licence/defence/offence, a doubled l (cancelled, labelled, travelled), and the single
/// words of `BritishSpelling.words`.
///
/// Allow-list (explicit, and small): `BritishSpelling.allowed` maps a catalog key to the words that may stay in
/// that key's values, for a text that quotes a name or a protocol string. Add a pair only with a reason in a comment
/// beside it; never a word for every key. Words that are US English too (advise, exercise,
/// surprise, compromise, enterprise, otherwise, precise, promise, raise, noise, premise, ...) are recognized by
/// `BritishSpelling.usIseWords` and need no entry. Keys, code identifiers, wire codes and comments are not checked.
struct AmericanSpellingTests {
    /// The repository's files are reached through `#filePath`: that works on the simulator and on the Mac, not on a phone.
    private static var onSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    @Test(.enabled(if: AmericanSpellingTests.onSimulator, "the sources are not on a phone"))
    func noCatalogTextUsesABritishSpelling() throws {
        let catalogs = try Self.catalogs()
        #expect(catalogs.count >= 13, "the catalogs were not found: \(catalogs.count)")
        var found: [String] = []
        for url in catalogs {
            let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let strings = root["strings"] as? [String: Any] ?? [:]
            for (key, entry) in strings.sorted(by: { $0.key < $1.key }) {
                var values = Self.values(in: entry)
                if (entry as? [String: Any])?["localizations"] == nil { values.append(key) }
                for value in values {
                    let allowed = BritishSpelling.allowed[key] ?? []
                    for word in BritishSpelling.hits(in: value) where !allowed.contains(word.lowercased()) {
                        found.append("\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent) \(key): \(word)")
                    }
                }
            }
        }
        #expect(found.isEmpty, "British spellings in catalog texts (use American English): \(found)")
    }

    @Test func theMatcherFlagsBritishAndKeepsAmericanSpellings() {
        let british = ["colour", "Favourite", "behaviour", "organise", "organisation", "recognised", "analyse", "centre", "metres",
                       "licence", "defence", "cancelled", "cancelling", "labelled", "travelled", "grey", "programme", "whilst",
                       "enrolment", "judgement", "practise", "catalogue", "dialling", "fibre", "jeweller", "vigour", "analyser", "enrol",
                       "marvellous", "woollen", "instil", "calibre", "dialled", "redialled"]
        for word in british { #expect(!BritishSpelling.hits(in: "a \(word) here").isEmpty, "\(word)") }
        let american = ["color", "favorite", "organize", "organization", "recognized", "analyze", "center", "meters", "license",
                        "defense", "canceled", "canceling", "cancellation", "labeled", "traveled", "gray", "program", "while",
                        "enrollment", "judgment", "practice", "advise", "revised", "exercise", "surprise", "compromised",
                        "enterprise", "otherwise", "precise", "promises", "raise", "noise", "premises", "towards", "wise", "analyses",
                        "cruise", "bruise", "turquoise", "called", "installed", "enrolled", "scrolled",
                        "controlled", "killed", "filled", "polled", "billed", "fulfilled", "prefilled", "refilled", "recalled",
                        "uninstalled", "unrolled", "distilled", "instilled", "appalled", "bestseller"]
        for word in american { #expect(BritishSpelling.hits(in: "a \(word) here").isEmpty, "\(word)") }
    }

    private static func catalogs() throws -> [URL] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var urls: [URL] = []
        for top in ["Packages", "App"] {
            let dir = repo.appendingPathComponent(top)
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker {
                if url.pathComponents.contains(".build") { walker.skipDescendants(); continue }
                if url.pathExtension == "xcstrings" { urls.append(url) }
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    /// Every `value` string of a catalog entry: any language, plural and device variation, and substitution.
    private static func values(in node: Any) -> [String] {
        if let dict = node as? [String: Any] {
            return dict.flatMap { key, child -> [String] in
                if key == "value", let text = child as? String { return [text] }
                return values(in: child)
            }
        }
        if let list = node as? [Any] { return list.flatMap { values(in: $0) } }
        return []
    }
}

enum BritishSpelling {
    /// Catalog key -> lowercase words that may stay in that key's values (see the guard's comment).
    static let allowed: [String: Set<String>] = [
        // The app's name must equal the vault registry's (`ItemTemplatesRegistryTests`); it changes when the registry does.
        "items_template_drivers_license": ["licence"]
    ]

    static let words: [String] = [
        "grey", "greys", "greyed", "programme", "programmes", "catalogue", "catalogues", "dialogue", "dialogues", "cheque", "cheques",
        "tyre", "tyres", "aluminium", "aeroplane", "plough", "mould", "moulds", "judgement", "judgements", "ageing", "acknowledgement",
        "acknowledgements", "whilst", "amongst", "learnt", "spelt", "dreamt", "storey", "storeys", "kerb", "practise", "practised",
        "practising", "sceptic", "sceptical", "artefact", "artefacts", "draught", "manoeuvre", "manoeuvres", "paediatric", "oestrogen",
        "encyclopaedia", "jewellery", "cosy", "moustache", "pyjamas", "fulfil", "enrolment", "enrolments", "instalment", "instalments",
        "skilful", "wilful", "marvellous", "woollen", "jeweller", "jewellers", "enrol", "enrols", "instil", "instils", "distil", "distils",
        "analyser", "analysers", "fibre", "fibres", "calibre", "spectre", "lustre", "sabre", "meagre", "licence", "licences",
        "defence", "defences", "offence", "offences", "pretence", "theatre", "theatres"
    ]

    /// -ise words that are US English too, by their base form (`-ise`).
    static let usIseWords: Set<String> = [
        "advise", "revise", "exercise", "surprise", "comprise", "compromise", "enterprise", "otherwise", "precise", "promise", "raise",
        "wise", "noise", "premise", "expertise", "franchise", "merchandise", "devise", "disguise", "supervise", "televise", "concise",
        "demise", "despise", "improvise", "incise", "paradise", "likewise", "praise", "arise", "rise", "apprise", "excise", "advertise",
        "chastise", "treatise", "clockwise", "reprise", "cruise", "bruise", "appraise", "poise", "turquoise", "tortoise"
    ]

    private static let patterns: [NSRegularExpression] = [
        #"\b\w*(?:colour|favour|behaviour|honour|neighbour|labour|rumour|harbour|flavour|armour|humour|"#
            + #"endeavour|vapour|odour|rigour|vigour|saviour|parlour|tumour|valour|candour|splendour|clamour)\w*\b"#,
        #"\b\w+isations?\b"#,
        #"\b\w+ys(?:e|ed|ing)\b"#,
        #"\b\w*(?:centre|metre|litre)s?\b"#,
        #"\b\w*(?:cancell|labell|travell|modell|signall|totall|fuell|counsell)(?:ed|er|ers|or|ors|ing)\b"#
    ].map { regex($0) }

    /// -ll- words that are US English too (the generic doubled-l rule skips them).
    static let usDoubledL: Set<String> = [
        "called", "calling", "caller", "callers", "filled", "filling", "filler", "installed", "installing", "installer", "controlled",
        "controlling", "controller", "controllers", "enrolled", "enrolling", "scrolled", "scrolling", "scroller", "rolled", "rolling",
        "roller", "killed", "killing", "killer", "spelled", "spelling", "pulled", "pulling", "puller", "polled", "polling", "billed",
        "billing", "willing", "falling", "telling", "teller", "seller", "sellers", "selling", "smelled", "smelling", "dwelling",
        "swelling", "yelling", "stalled", "stalling", "drilled", "drilling", "thrilled", "thrilling", "skilled", "chilled", "grilled",
        "grilling", "spilled", "spilling", "mulled", "culled", "lulled", "dulled", "milling", "miller", "shelled", "shelling",
        "yelled", "balled", "belling", "trolling", "troller", "walled", "welled", "swelled", "swelling", "knelled", "rebelling",
        "propelled", "propeller", "compelled", "compelling", "excelled", "excelling", "expelled", "repelled", "dispelled", "patrolled",
        "annulled", "annulling", "fulfilled", "fulfilling", "distilled", "distilling", "instilled", "instilling", "appalled",
        "appalling", "smaller", "taller", "fuller", "stiller"
    ]

    private static let doubledL = regex(#"\b\w+ll(?:ed|ing|er|ers)\b"#)
    private static let iseWord = regex(#"\b\w+(?:ise|ises|ised|ising)\b"#)
    private static let wordList = regex(#"\b(?:"# + words.joined(separator: "|") + #")\b"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// A US -ll- word, also with a prefix taken off (prefilled, uninstalled, recalled, bestseller).
    private static func isUSDoubledL(_ word: String) -> Bool {
        if usDoubledL.contains(word) { return true }
        return ["pre", "re", "un", "auto", "over", "best"].contains {
            word.hasPrefix($0) && usDoubledL.contains(String(word.dropFirst($0.count)))
        }
    }

    /// The British spellings in `text` (a word may repeat).
    static func hits(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var out: [String] = []
        for regex in patterns + [wordList] {
            for match in regex.matches(in: text, range: range) { out.append((text as NSString).substring(with: match.range)) }
        }
        for match in doubledL.matches(in: text, range: range) {
            let word = (text as NSString).substring(with: match.range)
            if !isUSDoubledL(word.lowercased()) { out.append(word) }
        }
        for match in iseWord.matches(in: text, range: range) {
            let word = (text as NSString).substring(with: match.range).lowercased()
            let suffix = ["ising", "ised", "ises", "ise"].first { word.hasSuffix($0) } ?? "ise"
            let base = String(word.dropLast(suffix.count)) + "ise"
            if !usIseWords.contains(base) { out.append(word) }
        }
        return out
    }
}
