import Foundation

/// The checks of VAULT-MESSAGING §10.11, as the vault makes them (vettid-vault `features/itemspec`), so that a setting the app
/// accepts is one the vault accepts; the vault decides, and its `bad_request` is shown when the two differ. The variable names
/// the vault refuses by name (code-loading and traffic names, `VETTID_IN`, `VETTID_OUT`) are not copied here (AA7: "The app does
/// not keep its own copy of that list"). Mirrors vettid-android `ItemWaysRules`; the reading of the answers is in
/// ``ItemWaysRules/list(_:agentID:)`` (``ItemWaysRules+Read``).
public enum ItemWaysRules {
    public static let maxPrograms = 16
    public static let maxProgramBytes = 4096
    public static let maxEnv = 32
    public static let maxHosts = 8
    public static let maxHeader = 64
    public static let maxPrefix = 32
    public static let maxFolders = 16
    private static let maxDNSName = 253
    private static let maxLabel = 63
    private static let maxPort = 65_535
    private static let maxPortDigits = 5
    private static let sha256Hex = 64
    /// A drive path's root, `X:\` or `X:/`, is this long.
    private static let driveRoot = 3

    private static let slash: Unicode.Scalar = "/"
    private static let backslash: Unicode.Scalar = "\\"

    private static let refusedHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "proxy-connection", "te", "trailer",
        "transfer-encoding", "upgrade", "host", "content-length", "cookie",
    ]
    private static let headerPunctuation = Set("!#$%&'*+.^_`|~-".unicodeScalars)

    private static func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }

    private static func string(_ s: some Collection<Unicode.Scalar>) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s)
        return String(out)
    }

    private static func isSeparator(_ c: Unicode.Scalar) -> Bool { c == slash || c == backslash }

    private static func isAsciiLetter(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }

    /// Absolute as the vault reads it: `/` then a name (never `//`), or a drive path `X:\` or `X:/` (never `X:\\`).
    public static func isAbsolute(_ p: String) -> Bool {
        let s = scalars(p)
        if s.first == slash { return !(s.count >= 2 && s[1] == slash) }
        return isDrivePath(s)
    }

    /// `X:\` or `X:/` and a name after it, never `X:\\` (a drive path's root followed by another separator).
    private static func isDrivePath(_ s: [Unicode.Scalar]) -> Bool {
        let root = s.count >= driveRoot && isAsciiLetter(s[0]) && s[1] == ":" && isSeparator(s[2])
        return root && !(s.count > driveRoot && isSeparator(s[driveRoot]))
    }

    /// A path's last element (after the last `/` or `\`).
    public static func lastElement(_ p: String) -> String {
        let s = scalars(p)
        guard let i = s.lastIndex(where: isSeparator) else { return p }
        return string(s[(i + 1)...])
    }

    /// No control, format (Cf), line or paragraph separator character: what the vault refuses in a path.
    public static func showable(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { c in
            switch c.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate: false
            default: true
            }
        }
    }

    /// After the root, no empty element, no `.` or `..` element and no `:` (vettid-vault `cleanPath`, the root itself refused).
    private static func cleanPath(_ p: String) -> Bool {
        let s = scalars(p)
        let rest = s.first == slash ? Array(s.dropFirst()) : Array(s.dropFirst(driveRoot))
        if rest.isEmpty { return false }
        return rest.split(omittingEmptySubsequences: false, whereSeparator: isSeparator).allSatisfy { part in
            !part.isEmpty && string(part) != "." && string(part) != ".." && !part.contains(":")
        }
    }

    private static func trimEnd(_ s: [Unicode.Scalar], _ chars: Set<Unicode.Scalar>) -> [Unicode.Scalar] {
        var out = s
        while let l = out.last, chars.contains(l) { out.removeLast() }
        return out
    }

    private static func trimBoth(_ s: [Unicode.Scalar], _ chars: Set<Unicode.Scalar>) -> [Unicode.Scalar] {
        var out = trimEnd(s, chars)
        while let f = out.first, chars.contains(f) { out.removeFirst() }
        return out
    }

    private static let spaceDot: Set<Unicode.Scalar> = [" ", "."]

    /// The key two programs are compared by (the no-two-match rule, 0.85.3): without case and without a final `.exe`, a drive
    /// path's `/` as `\`, trailing dots and spaces of the last element dropped.
    public static func programKey(_ p: String) -> String {
        let k = simpleLower(p)
        let i = k.lastIndex(where: isSeparator)
        var dir = i.map { Array(k[...$0]) } ?? []
        var last = i.map { Array(k[($0 + 1)...]) } ?? k
        if dir.count >= driveRoot, dir[0] >= "a", dir[0] <= "z", dir[1] == ":" { dir = dir.map { $0 == slash ? backslash : $0 } }
        last = trimEnd(last, spaceDot)
        let exe = Array(".exe".unicodeScalars)
        if last.count >= exe.count, Array(last.suffix(exe.count)) == exe { last.removeLast(exe.count) }
        last = trimEnd(last, spaceDot)
        return string(dir + last)
    }

    /// Lower case rune by rune with the simple mapping, as Go's `strings.ToLower` (no final sigma, `İ` one rune). Swift's
    /// mapping of a single scalar is context free; the one scalar it maps to two (`İ`, U+0130, to `i` and a combining dot)
    /// is `i` in the simple mapping.
    private static func simpleLower(_ s: String) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        for c in s.unicodeScalars {
            let m = Array(c.properties.lowercaseMapping.unicodeScalars)
            if m.count == 1 {
                out.append(m[0])
            } else if c.value == 0x130 {
                out.append("i")
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Why [program] can't be a binding's program, or nil when it can ("Program strings").
    public static func programProblem(_ program: String) -> ProgramProblem? { // swiftlint:disable:this cyclomatic_complexity
        let s = scalars(program)
        if program.utf8.count > maxProgramBytes { return .tooLong }
        if s.isEmpty { return .notPathOrName }
        if !showable(program) { return .characters }
        if s.count >= 2, s[0] == s[1], isSeparator(s[0]) { return .networkPath }
        if isAbsolute(program) {
            if !cleanPath(program) { return .pathParts }
            if trimEnd(scalars(lastElement(program)), spaceDot).isEmpty { return .notPathOrName }
        } else {
            if s.contains(where: isSeparator) { return .notPathOrName }
            if s.contains(":") { return .pathParts }
            if trimBoth(s, spaceDot).isEmpty { return .notPathOrName }
        }
        // An 8.3 short name (BASH~1.EXE) would read on the phone as another program (owner decision a, #14596).
        if lastElement(program).unicodeScalars.contains("~") { return .tilde }
        return nil
    }

    /// Why [program] can't be added to [programs]: its own problem, a duplicate by the no-two-match rule, or the limit.
    public static func addProgramProblem(_ programs: [RunProgram], _ program: String) -> ProgramProblem? {
        if let p = programProblem(program) { return p }
        if duplicates(programs.map(\.program), program) { return .duplicate }
        if programs.count >= maxPrograms { return .tooMany }
        return nil
    }

    /// Whether [program] collides with one of [existing] (0.85.3): equal keys, or a bare name equal to an absolute entry's last
    /// element (either way round).
    public static func duplicates(_ existing: [String], _ program: String) -> Bool {
        let k = programKey(program)
        return existing.contains { e in
            same(programKey(e), k)
                || isAbsolute(program) && !isAbsolute(e) && same(programKey(lastElement(program)), programKey(e))
                || !isAbsolute(program) && isAbsolute(e) && same(programKey(lastElement(e)), k)
        }
    }

    /// Why [name] can't be added to [env] (the form only; the vault refuses named ones with `bad_request`). A name already in
    /// [env] is no problem here: adding it again changes nothing, which the page sees to.
    public static func variableProblem(_ env: [String], _ name: String) -> VariableProblem? {
        if !envName(name) { return .form }
        if !env.contains(where: { same($0, name) }) && env.count >= maxEnv { return .tooMany }
        return nil
    }

    /// `[A-Z_][A-Z0-9_]{0,63}`, the whole name.
    static func envName(_ n: String) -> Bool {
        let s = Array(n.utf8)
        guard (1...64).contains(s.count) else { return false }
        let upper = { (c: UInt8) in c >= 0x41 && c <= 0x5A }
        return (upper(s[0]) || s[0] == 0x5F) && s.dropFirst().allSatisfy { upper($0) || (0x30...0x39).contains($0) || $0 == 0x5F }
    }

    /// A host as typed, lowercased (AA7: "The app lowercases it").
    public static func normalizeHost(_ h: String) -> String { h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// The key two hosts are compared by: the default port made explicit.
    public static func hostKey(_ h: String) -> String { h.unicodeScalars.contains(":") ? h : "\(h):443" }

    /// Why [host] (already lowercased) is not one §10.11 allows, or nil.
    public static func hostProblem(_ host: String) -> HostProblem? {
        let s = scalars(host)
        if s.contains("*") { return .wildcard }
        if s.contains("[") || s.filter({ $0 == ":" }).count > 1 { return .ipAddress }
        var name = s
        if let colon = s.lastIndex(of: ":") {
            name = Array(s[..<colon])
            if !portValid(Array(s[(colon + 1)...])) { return .notAHost }
        }
        if name.isEmpty || string(name).utf16.count > maxDNSName { return .notAHost }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map { Array($0) }
        let last = labels[labels.count - 1]
        if !last.isEmpty, last.allSatisfy(isDigit) || string(last).hasPrefix("0x") { return .ipAddress }
        if labels.count < 2 || string(last) == "localhost" { return .local }
        let ok = labels.allSatisfy { l in
            !l.isEmpty && string(l).utf16.count <= maxLabel && l[0] != "-" && l[l.count - 1] != "-"
                && l.allSatisfy { ($0 >= "a" && $0 <= "z") || isDigit($0) || $0 == "-" }
        }
        return ok ? nil : .notAHost
    }

    /// A port of 1–65,535, written plainly (no sign, no leading zero).
    private static func portValid(_ port: [Unicode.Scalar]) -> Bool {
        guard (1...maxPortDigits).contains(port.count), port[0] != "0", port.allSatisfy(isDigit) else { return false }
        return Int(string(port)).map { $0 <= maxPort } ?? false
    }

    /// Why [host] can't be added to [hosts]: its own problem, a duplicate (by ``hostKey(_:)``) or the limit.
    public static func addHostProblem(_ hosts: [String], _ host: String) -> HostProblem? {
        if let p = hostProblem(host) { return p }
        if hosts.contains(where: { same(hostKey($0), hostKey(host)) }) { return .duplicate }
        if hosts.count >= maxHosts { return .tooMany }
        return nil
    }

    /// A header that can carry the key: a token of 1–64 characters, not hop-by-hop, `Host`, `Content-Length`,
    /// `Transfer-Encoding` or `Cookie`.
    public static func headerValid(_ h: String) -> Bool {
        let s = scalars(h)
        let token = s.allSatisfy { isAsciiLetter($0) || isDigit($0) || headerPunctuation.contains($0) }
        return (1...maxHeader).contains(s.count) && token && !refusedHeaders.contains(h.lowercased())
    }

    /// What goes before the key: 0–32 printable ASCII characters.
    public static func prefixValid(_ p: String) -> Bool {
        p.unicodeScalars.count <= maxPrefix && p.unicodeScalars.allSatisfy { $0 >= " " && $0 <= "~" }
    }

    static func isSha256(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return b.count == sha256Hex && b.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Header names compared without case, by ASCII only (a non-ASCII difference is a change: the direction that asks for the
    /// password).
    private static func sameHeader(_ a: String, _ b: String) -> Bool {
        let fold = { (s: String) in s.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 } }
        return fold(a) == fold(b)
    }

    /// Whether [next] allows more than [cur] (VAULT-MESSAGING §10.11 "Widening needs the member", as vettid-vault's `Widens`): a
    /// way, a program or a host added, programs emptied, a variable added to a program, Ask me before each run turned off, the
    /// header's name changed (not only its case), a folder added or its write turned on (AA9). Binding an unbound item narrows
    /// unless a program lists a variable or each is off; a full path that replaces a name narrows only when its last part is
    /// exactly that name and it adds no variable.
    public static func widens(_ cur: ItemWays?, _ next: ItemWays) -> Bool {
        let curWays = cur?.ways ?? [.use]
        if !next.ways.isSubset(of: curWays) { return true }
        if let nr = next.run, let cr = cur?.run, runWidens(cr, nr) { return true }
        if let np = next.proxy, let cp = cur?.proxy {
            if !sameHeader(np.header, cp.header) { return true }
            let have = Set(cp.hosts.map { Array(hostKey($0).utf8) })
            if np.hosts.contains(where: { !have.contains(Array(hostKey($0).utf8)) }) { return true }
        }
        return false
    }

    private static func runWidens(_ cr: RunSettings, _ nr: RunSettings) -> Bool {
        if nr.programs.isEmpty && !cr.programs.isEmpty { return true }
        let unbound = cr.programs.isEmpty
        for p in nr.programs {
            let q: RunProgram
            if let exact = cr.programs.first(where: { same($0.program, p.program) }) {
                q = exact
            } else if unbound {
                q = RunProgram(program: "")
            } else if isAbsolute(p.program),
                      let named = cr.programs.first(where: { !isAbsolute($0.program) && same($0.program, lastElement(p.program)) }) {
                q = named
            } else {
                return true
            }
            if p.env.contains(where: { v in !q.env.contains { same($0, v) } }) { return true }
        }
        if !nr.each && cr.each { return true }
        for f in nr.folders ?? [] {
            let g = (cr.folders ?? []).first { same($0.path, f.path) }
            if g == nil || f.write && g?.write == false { return true }
        }
        return false
    }
}
