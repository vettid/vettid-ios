import Foundation
import VettIDCrypto
import VettIDVault

/// An agent's `item.run`, `item.proxy` and `item.get` held for approval, read as ANDROID-PLAN 0.1.138 AA8 "Fail closed" says:
/// from the whole `approval.pending` (or its `pending.list` entry) read strictly, so a duplicate member anywhere has already
/// made it unreadable (``ApprovalParser/denyOnly(_:)``). Anything this version does not know, or that does not fit, is
/// ``HeldApproval/unshown`` (deny only). Pure. Mirrors vettid-android `AgentApprovals`.
public enum AgentApprovals {
    private static func names(_ n: String...) -> Set<[UInt8]> { Set(n.map { Array($0.utf8) }) }

    /// `approval.pending`'s members (VAULT-MESSAGING 0.93.2 §6.8 step 1); any other makes these ops deny only.
    private static let top = names(
        "approval_id", "device_id", "role", "name", "type", "body", "exp",
        "flags", "previous_sha256", "previous_path", "replaces", "proxy", "folders"
    )

    /// An `item.run` body's members (VAULT-MESSAGING's `agent.request` row).
    private static let runBody = names("op", "item_id", "field_id", "program", "sha256", "argv", "cwd", "how", "name", "env", "inputs", "output")

    /// An `item.proxy` body's members.
    private static let proxyBody = names("op", "item_id", "field_id", "host", "seconds")

    /// `proxy`'s members (0.92.0).
    private static let proxyNote = names("host", "header", "prefix")

    /// The members only a run of AA9 (member folders and files) carries: until AA9 is built such a run is deny only.
    private static let aa9Top = names("folders")
    private static let aa9Body = names("inputs", "output")
    private static let aa9Flags: Set<RunFlag> = [.memberFolder, .memberFiles]

    /// A run's program is unbound, unrecorded or changed: never two of these.
    private static let pinStates: Set<RunFlag> = [.unboundProgram, .programUnrecorded, .programChanged]

    /// A proxy's length (`body.seconds`): 60 to 3,600, 900 when absent.
    public static let minSeconds = 60
    public static let maxSeconds = 3_600
    public static let defaultSeconds = 900

    /// The members that change what approving means: on an `item.use` or a `catalog` none of them may appear (AA8).
    private static let meaningful = ["flags", "previous_sha256", "previous_path", "replaces", "proxy", "folders"]

    /// An `item.use`'s or a `catalog`'s envelope, read strictly (so no duplicate member): none of the members that change what
    /// approving means. Another unknown member is ignored, as §6.8 step 1 says for these types.
    static func plainShown(_ p: JsonObject) -> Bool {
        guard case .object? = p["body"] else { return false }
        return !meaningful.contains { p.has($0) }
    }

    /// An `item.get`'s envelope: known members only, no `proxy` or `replaces`, and `flags` at most `history`. The body's
    /// members are not judged.
    static func getShown(_ p: JsonObject) -> Bool {
        guard case .object? = p["body"], let flags = flags(p) else { return false }
        return envelope(p, allowProxy: false, allowReplaces: false) && flags.allSatisfy { $0 == "history" } && noRunMembers(p)
    }

    /// An `item.run`, or ``HeldApproval/unshown``.
    static func run(_ p: JsonObject) -> HeldApproval { // swiftlint:disable:this cyclomatic_complexity function_body_length
        guard envelope(p, allowProxy: false, allowReplaces: true), case .object(let body)? = p["body"],
              body.members.allSatisfy({ runBody.contains(Array($0.name.utf8)) }), let wire = flags(p) else { return .unshown }
        var flags = Set<RunFlag>()
        for w in wire {
            guard let f = RunFlag.of(w) else { return .unshown }
            flags.insert(f)
        }
        if aa9(flags, p, body) { return .unshown }
        // Flags that contradict: at most one of unbound, unrecorded and changed.
        if flags.filter({ pinStates.contains($0) }).count > 1 { return .unshown }
        let changed = flags.contains(.programChanged)
        guard let item = str(body, "item_id"), !item.isEmpty, let field = str(body, "field_id"), !field.isEmpty,
              let program = str(body, "program"), let sha = hex64(body, "sha256"), let argv = strings(body["argv"]), !argv.isEmpty,
              let how = SecretHow.of(str(body, "how")) else { return .unshown }
        var cwd: String?
        if body.has("cwd") {
            guard let c = str(body, "cwd") else { return .unshown }
            cwd = c
        }
        var name: String?
        if body.has("name") {
            guard let n = str(body, "name") else { return .unshown }
            name = n
        }
        if how != .stdin && name == nil { return .unshown }
        var env: [ItemRun.EnvEntry] = []
        if body.has("env") {
            guard case .object(let o)? = body["env"] else { return .unshown }
            for (k, v) in o.members {
                guard case .string(_, let s) = v else { return .unshown }
                env.append(ItemRun.EnvEntry(name: k, value: s))
            }
        }
        // previous_* come with program_changed, and only with it.
        var prevSha: String?
        if p.has("previous_sha256") {
            guard let h = hex64(p, "previous_sha256") else { return .unshown }
            prevSha = h
        }
        var prevPath: String?
        if p.has("previous_path") {
            guard let v = str(p, "previous_path") else { return .unshown }
            prevPath = v
        }
        if changed != (prevSha != nil) || changed != (prevPath != nil) { return .unshown }
        guard replacesOk(p) else { return .unshown }
        return .itemRun(ItemRun(
            itemID: item, fieldID: field, program: program, sha256: sha, argv: argv, cwd: cwd, how: how, name: name, env: env,
            flags: flags, previousSha256: prevSha, previousPath: prevPath, replaces: str(p, "replaces")
        ))
    }

    /// An `item.proxy`, or ``HeldApproval/unshown``.
    static func proxy(_ p: JsonObject) -> HeldApproval {
        guard envelope(p, allowProxy: true, allowReplaces: true), noRunMembers(p), case .object(let body)? = p["body"],
              body.members.allSatisfy({ proxyBody.contains(Array($0.name.utf8)) }),
              // Any flag on a proxy.
              let wire = flags(p), wire.isEmpty,
              let item = str(body, "item_id"), !item.isEmpty, let field = str(body, "field_id"), !field.isEmpty else { return .unshown }
        var seconds = defaultSeconds
        if let v = body["seconds"] {
            guard let s = self.seconds(v) else { return .unshown }
            seconds = s
        }
        // Shown only from a well-formed `proxy` member.
        guard case .object(let note)? = p["proxy"], note.members.allSatisfy({ proxyNote.contains(Array($0.name.utf8)) }),
              let host = str(note, "host"), host == ItemWaysRules.normalizeHost(host), ItemWaysRules.hostProblem(host) == nil,
              let header = str(note, "header"), ItemWaysRules.headerValid(header),
              let prefix = str(note, "prefix"), ItemWaysRules.prefixValid(prefix), replacesOk(p) else { return .unshown }
        return .itemProxy(ItemProxy(
            itemID: item, fieldID: field, host: host, header: header, prefix: prefix, seconds: seconds, replaces: str(p, "replaces")
        ))
    }

    /// Known top-level members only; `proxy` and `replaces` only where they belong.
    private static func envelope(_ p: JsonObject, allowProxy: Bool, allowReplaces: Bool) -> Bool {
        p.members.allSatisfy { top.contains(Array($0.name.utf8)) } && (allowProxy || !p.has("proxy")) && (allowReplaces || !p.has("replaces"))
    }

    /// No member a run alone carries.
    private static func noRunMembers(_ p: JsonObject) -> Bool {
        !p.has("previous_sha256") && !p.has("previous_path") && !p.has("folders")
    }

    /// `flags` as wire strings: absent is none; not a list of distinct strings is nil.
    private static func flags(_ p: JsonObject) -> [String]? {
        guard let v = p["flags"] else { return [] }
        guard let names = strings(v), Set(names.map { Array($0.utf8) }).count == names.count else { return nil }
        return names
    }

    /// Until AA9 is built, a run with member folders or files is not shown.
    private static func aa9(_ flags: Set<RunFlag>, _ p: JsonObject, _ body: JsonObject) -> Bool {
        !flags.isDisjoint(with: aa9Flags) || p.members.contains { aa9Top.contains(Array($0.name.utf8)) }
            || body.members.contains { aa9Body.contains(Array($0.name.utf8)) }
    }

    private static func hex64(_ o: JsonObject, _ name: String) -> String? {
        guard let s = str(o, name) else { return nil }
        let b = Array(s.utf8)
        return b.count == 64 && b.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) } ? s : nil
    }

    /// `replaces` is absent, or a non-empty string.
    private static func replacesOk(_ p: JsonObject) -> Bool { !p.has("replaces") || str(p, "replaces").map { !$0.isEmpty } == true }

    /// A whole number as JSON writes it (no sign, fraction or exponent), 60 to 3,600; else nil.
    private static func seconds(_ v: JsonValue) -> Int? {
        guard case .number(let raw) = v, !raw.isEmpty, raw.utf8.count <= 4, raw.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              raw == "0" || raw.utf8.first != 0x30, let n = Int(raw), (minSeconds...maxSeconds).contains(n) else { return nil }
        return n
    }

    private static func str(_ o: JsonObject, _ name: String) -> String? { VaultJSON.string(o, name) }

    /// An array of strings, or nil for anything else.
    private static func strings(_ v: JsonValue?) -> [String]? {
        guard case .array(_, let items)? = v else { return nil }
        var out: [String] = []
        for i in items {
            guard case .string(_, let s) = i else { return nil }
            out.append(s)
        }
        return out
    }
}
