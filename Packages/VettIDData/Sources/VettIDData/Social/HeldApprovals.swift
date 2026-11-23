import Foundation
import VettIDCrypto
import VettIDVault

/// What a request held for approval asks (`approval.pending{type, body}`, VAULT-MESSAGING §6.8, §10.11), as far as this app
/// can read it (ANDROID-PLAN 0.1.116 §4 "Approvals for devices and agents (AA5)", 0.1.138 AA8). Anything the app cannot read
/// in full is ``unshown``: that can only be denied, never approved unseen (decision 10). Mirrors vettid-android `HeldApproval`.
///
/// None of these prints what it holds: an agent chooses `data`, `fields`, `argv` and the rest.
public enum HeldApproval: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// `agent.request{op: "item.use"}`: HMAC-SHA-256 keyed by the field's value over [data] (1-16,384 bytes).
    case itemUse(itemID: String, fieldID: String, data: [UInt8])
    /// `agent.request{op: "item.get"}`: a reveal. [fieldIDs] nil: all fields and the notes.
    case itemGet(itemID: String, fieldIDs: [String]?)
    /// `agent.request{op: "catalog"}`: the names and field labels of the items the agent may use.
    case catalog
    /// `agent.request{op: "item.run"}` as ANDROID-PLAN 0.1.138 AA8 shows it, read strictly from `approval.pending` ("Fail
    /// closed", ``AgentApprovals``).
    case itemRun(ItemRun)
    /// `agent.request{op: "item.proxy"}` (AA8).
    case itemProxy(ItemProxy)
    /// A desktop's step-up request (decision 9): deny only.
    case desktopStepUp
    /// Any other type or op, or a body that does not read: deny only.
    case unshown

    /// Whether the request can be approved here: only what the app shows in full. A run and a proxy are read (AA8's rules)
    /// but not yet approvable: their screens come with the next step, so they stay deny only until then.
    public var approvable: Bool {
        switch self {
        case .itemUse, .itemGet, .catalog: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .itemUse: "ItemUse"
        case .itemGet: "ItemGet"
        case .catalog: "Catalog"
        case .itemRun: "ItemRun"
        case .itemProxy: "ItemProxy"
        case .desktopStepUp: "DesktopStepUp"
        case .unshown: "Unshown"
        }
    }

    public var debugDescription: String { description }
}

/// An `item.run` held for approval, everything from the vault's `approval.pending` (`body`, `flags`, `previous_*`,
/// `replaces`), never the app's copy of the item's settings.
public struct ItemRun: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var itemID: String
    public var fieldID: String
    public var program: String
    /// 64 lowercase hex digits.
    public var sha256: String
    public var argv: [String]
    public var cwd: String?
    public var how: SecretHow
    public var name: String?
    /// The body's `env`, in its order.
    public var env: [EnvEntry]
    public var flags: Set<RunFlag>
    public var previousSha256: String?
    public var previousPath: String?
    public var replaces: String?

    /// A `cwd`, here always without `member_folder`, which a vault that carries `run.folders` never sends: judged against the
    /// item's settings before it may be approved (AA8; ``ItemWaysRules/runCwdAllowed(_:)``).
    public var hasCwd: Bool { cwd != nil }

    public var description: String { "ItemRun" }
    public var debugDescription: String { "ItemRun" }

    public struct EnvEntry: Equatable, Sendable {
        public var name: String
        public var value: String
    }
}

/// An `item.proxy` held for approval (AA8): [host], [header] and [prefix] from `approval.pending`'s `proxy` (the vault's
/// note, never the app's copy), [seconds] from the body (900 when absent).
public struct ItemProxy: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var itemID: String
    public var fieldID: String
    public var host: String
    public var header: String
    public var prefix: String
    public var seconds: Int
    public var replaces: String?

    public var description: String { "ItemProxy" }
    public var debugDescription: String { "ItemProxy" }
}

/// How a run gets the secret (`body.how`).
public enum SecretHow: String, Sendable, CaseIterable {
    case env, stdin, file

    public static func of(_ wire: String?) -> SecretHow? { wire.flatMap(SecretHow.init(rawValue:)) }
}

/// A run's `flags` (VAULT-MESSAGING §10.11 "The approval").
public enum RunFlag: String, Sendable, CaseIterable {
    case shell
    case inlineCode = "inline_code"
    case unboundProgram = "unbound_program"
    case programUnrecorded = "program_unrecorded"
    case programChanged = "program_changed"
    case memberFolder = "member_folder"
    case memberFiles = "member_files"

    public static func of(_ wire: String) -> RunFlag? { RunFlag(rawValue: wire) }
}

/// Reads a held request from the event's `role`, `type` and `body` (§6.8: `body` is the held request's body).
public enum HeldApprovals {
    /// `item.use`'s data bound (§10.11).
    public static let maxData = 16_384
    /// The most field ids an `item.get` is shown with.
    public static let maxFields = 64

    /// [pending] is the whole `approval.pending` (or its `pending.list` entry) read strictly: every agent op is deny only
    /// without it (AA8 "Fail closed"; VAULT-MESSAGING 0.93.2 §6.8 step 1). A run, a proxy and a reveal are deny only on any
    /// member this version does not know; an `item.use` and a `catalog` ignore an unknown member, but not one that changes
    /// what approving means.
    public static func of(role: String?, type: String?, body: JsonObject?, pending: JsonObject?) -> HeldApproval {
        if role == "desktop" { return .desktopStepUp }
        guard role == "agent", type == "agent.request", let body else { return .unshown }
        return agentRequest(body, pending)
    }

    private static func agentRequest(_ body: JsonObject, _ pending: JsonObject?) -> HeldApproval {
        guard let pending else { return .unshown }
        switch VaultJSON.string(body, "op") {
        // §6.8 step 1: these ignore an unknown member, but never one that changes what approving means (AA8).
        case "item.use": return AgentApprovals.plainShown(pending) ? itemUse(body) : .unshown
        case "item.get": return AgentApprovals.getShown(pending) ? itemGet(body) : .unshown
        case "catalog": return AgentApprovals.plainShown(pending) ? .catalog : .unshown
        case "item.run": return AgentApprovals.run(pending)
        case "item.proxy": return AgentApprovals.proxy(pending)
        default: return .unshown
        }
    }

    private static func itemUse(_ b: JsonObject) -> HeldApproval {
        let item = VaultJSON.string(b, "item_id").flatMap { $0.isEmpty ? nil : $0 }
        let field = VaultJSON.string(b, "field_id").flatMap { $0.isEmpty ? nil : $0 }
        let data = VaultJSON.string(b, "data").flatMap(decode)
        // A request that does not read in full is never offered for approval (it is not shown unseen).
        guard let item, let field, let data, VaultJSON.string(b, "action") == "hmac-sha256" else { return .unshown }
        return .itemUse(itemID: item, fieldID: field, data: data)
    }

    private static func itemGet(_ b: JsonObject) -> HeldApproval {
        guard let item = VaultJSON.string(b, "item_id"), !item.isEmpty else { return .unshown }
        var fields: [String]?
        if let raw = b["fields"] {
            guard case .array(_, let items) = raw else { return .unshown }
            var names: [String] = []
            for e in items {
                guard case .string(_, let v) = e else { return .unshown }
                names.append(v)
            }
            // An empty list (a vault may read it as "all fields"), a repeated id or more than 64 are not shown unseen.
            guard !names.isEmpty, names.count <= maxFields, Set(names).count == names.count else { return .unshown }
            fields = names
        }
        return .itemGet(itemID: item, fieldIDs: fields)
    }

    /// Standard base64, 1-16,384 bytes; nil when it is not (chosen; not in the spec: canonical base64 as the rest of the app
    /// reads it, where Android's decoder is Java's).
    private static func decode(_ s: String) -> [UInt8]? {
        (try? Base64s.decodeStd(s, -1)).flatMap { (1...maxData).contains($0.count) ? $0 : nil }
    }
}
