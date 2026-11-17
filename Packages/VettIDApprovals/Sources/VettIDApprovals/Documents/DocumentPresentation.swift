import Foundation
import VettIDCrypto
import VettIDData

/// What the approval screen shows of a checked document (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents", "What the
/// app shows"), in its order: what is asked, the service's description (`context`), its summary, and the request, as a
/// form for a known action whose payload matches it exactly, otherwise the whole document's raw view. Every string is a
/// ``ShownText``; the labels are the screen's own (never a value), and no default value ever goes under one.
public struct DocumentPresentation: Equatable, Sendable {
    public var asked: Asked
    /// The service's own line (`context`), when the challenge has one.
    public var context: ShownText?
    public var summary: ShownText
    public var request: Request

    /// 1. What is asked: the app's own title for a known action, else the action's name with the warning.
    public enum Asked: Equatable, Sendable {
        case known(KnownAction)
        case unknown(String)
    }

    /// The actions service-vault asks approval for (SERVICE-VAULT §7), with the app's title for each.
    public enum KnownAction: String, CaseIterable, Sendable {
        case proposalCreate = "proposal.create"
        case voteExtend = "vote.extend"
        case adminSetAdd = "admin_set.add"
        case adminSetRemove = "admin_set.remove"
        case adminRepin = "admin.repin"
        case contractTemplateChange = "contract_template.change"
        case assignmentPush = "assignment.push"
    }

    /// 4. The request.
    public enum Request: Equatable, Sendable {
        case proposal(ProposalForm)
        case extend(ExtendForm)
        /// "Request details": the whole document, a line to a member or element.
        case raw([RawLine])
    }

    /// `proposal.create`'s form, its fields in the screen's order.
    public struct ProposalForm: Equatable, Sendable {
        public var title: ShownText
        /// Motion; nil when empty ("None").
        public var text: ShownText?
        public var choices: [ShownText]
        public var quorumBallots: UInt64
        /// Quorum's text; nil when empty.
        public var quorumText: ShownText?
        public var binding: Bool
        public var removedMayVote: Bool
        public var opensAt: Int64
        public var closesAt: Int64
        public var outageRule: ShownText
    }

    /// `vote.extend`'s form.
    public struct ExtendForm: Equatable, Sendable {
        /// The vote, shown as it is.
        public var proposalID: ShownText
        public var closesAt: Int64
        public var outageFrom: Int64
        public var outageTo: Int64
        public var outageSource: ShownText
    }

    /// One line of the raw view: indented by [depth], a member's [key] (nil for an array element or the document
    /// itself), its value or the bracket that opens or closes a container, and a comma after it when another member or
    /// element follows.
    public struct RawLine: Equatable, Sendable {
        public var depth: Int
        public var key: ShownText?
        public var value: RawValue
        public var comma: Bool
    }

    public enum RawValue: Equatable, Sendable {
        /// Shown with its quotation marks, outside its isolate.
        case string(ShownText)
        case number(String)
        case bool(Bool)
        case null
        /// `{` or `[` opening a container whose members follow; ``close(_:)`` ends it.
        case open(Container)
        case close(Container)
        /// `{}` or `[]`.
        case empty(Container)
    }

    public enum Container: Equatable, Sendable { case object, array }

    /// The latest time a form shows: 9999-12-31 23:59:59 UTC.
    public static let maxTime: Int64 = 253_402_300_799

    public init(_ d: ApprovalDocument, context: String?) {
        asked = KnownAction(rawValue: d.action).map(Asked.known) ?? .unknown(d.action)
        self.context = context.map { ShownText($0) }
        summary = ShownText(d.summary)
        let known = KnownAction(rawValue: d.action)
        if known == .proposalCreate, let f = Self.proposal(d.payload) {
            request = .proposal(f)
        } else if known == .voteExtend, let f = Self.extend(d.payload) {
            request = .extend(f)
        } else {
            request = .raw(Self.raw(d))
        }
    }

    // MARK: - Forms

    /// The payload's members, when they are exactly [names].
    private static func exactly(_ o: JsonObject, _ names: Set<String>) -> [String: JsonValue]? {
        guard o.members.count == names.count else { return nil }
        var out: [String: JsonValue] = [:]
        for m in o.members {
            guard names.contains(m.name) else { return nil }
            out[m.name] = m.value
        }
        return out.count == names.count ? out : nil
    }

    private static func string(_ v: JsonValue?) -> String? {
        if case .string(_, let s)? = v { return s }
        return nil
    }

    private static func bool(_ v: JsonValue?) -> Bool? {
        if case .bool(_, let b)? = v { return b }
        return nil
    }

    private static func integer(_ v: JsonValue?) -> UInt64? {
        guard case .number(let raw)? = v, Jcs.isInteger(raw) else { return nil }
        return UInt64(raw)
    }

    private static func time(_ v: JsonValue?) -> Int64? {
        guard let n = integer(v), n <= UInt64(maxTime) else { return nil }
        return Int64(n)
    }

    private static func object(_ v: JsonValue?, _ names: Set<String>) -> [String: JsonValue]? {
        guard case .object(let o)? = v else { return nil }
        return exactly(o, names)
    }

    static func proposal(_ payload: JsonObject) -> ProposalForm? {
        let names: Set = ["title", "text", "choices", "quorum", "binding", "removed_may_vote", "opens_at", "closes_at", "outage_rule"]
        guard let m = exactly(payload, names), let title = string(m["title"]), let text = string(m["text"]),
              case .array(_, let items)? = m["choices"], let quorum = object(m["quorum"], ["text", "min_ballots"]),
              let quorumText = string(quorum["text"]), let ballots = integer(quorum["min_ballots"]),
              let binding = bool(m["binding"]), let removed = bool(m["removed_may_vote"]), let opens = time(m["opens_at"]),
              let closes = time(m["closes_at"]), let outage = string(m["outage_rule"])
        else { return nil }
        var choices: [ShownText] = []
        for item in items {
            guard let c = object(item, ["label"]), let label = string(c["label"]) else { return nil }
            choices.append(ShownText(label))
        }
        return ProposalForm(
            title: ShownText(title), text: text.isEmpty ? nil : ShownText(text, lineBreaks: true), choices: choices,
            quorumBallots: ballots, quorumText: quorumText.isEmpty ? nil : ShownText(quorumText, lineBreaks: true),
            binding: binding, removedMayVote: removed, opensAt: opens, closesAt: closes, outageRule: ShownText(outage)
        )
    }

    static func extend(_ payload: JsonObject) -> ExtendForm? {
        guard let m = exactly(payload, ["proposal_id", "closes_at", "outage"]), let id = string(m["proposal_id"]),
              let closes = time(m["closes_at"]), let outage = object(m["outage"], ["from", "to", "source"]),
              let from = time(outage["from"]), let to = time(outage["to"]), let source = string(outage["source"])
        else { return nil }
        return ExtendForm(
            proposalID: ShownText(id), closesAt: closes, outageFrom: from, outageTo: to, outageSource: ShownText(source)
        )
    }

    // MARK: - The raw view

    /// The whole document, in its (canonical) order.
    static func raw(_ d: ApprovalDocument) -> [RawLine] {
        var lines: [RawLine] = []
        appendLines(.object(rawObject(d)), key: nil, depth: 0, comma: false, to: &lines)
        return lines
    }

    /// The document's own object: `action`, `payload` and `summary` in canonical order.
    private static func rawObject(_ d: ApprovalDocument) -> JsonObject {
        // The checked bytes parse again exactly as they did (they are strict and canonical).
        (try? StrictJson.parseObject(d.bytes, maxDepth: ApprovalDocument.maxDepth)) ?? d.payload
    }

    private static func appendLines(_ v: JsonValue, key: String?, depth: Int, comma: Bool, to lines: inout [RawLine]) {
        let k = key.map { ShownText($0) }
        switch v {
        case .string(_, let s): lines.append(RawLine(depth: depth, key: k, value: .string(ShownText(s)), comma: comma))
        case .number(let raw): lines.append(RawLine(depth: depth, key: k, value: .number(raw), comma: comma))
        case .bool(_, let b): lines.append(RawLine(depth: depth, key: k, value: .bool(b), comma: comma))
        case .null: lines.append(RawLine(depth: depth, key: k, value: .null, comma: comma))
        case .array(_, let items):
            guard !items.isEmpty else { return lines.append(RawLine(depth: depth, key: k, value: .empty(.array), comma: comma)) }
            lines.append(RawLine(depth: depth, key: k, value: .open(.array), comma: false))
            for (i, e) in items.enumerated() {
                appendLines(e, key: nil, depth: depth + 1, comma: i < items.count - 1, to: &lines)
            }
            lines.append(RawLine(depth: depth, key: nil, value: .close(.array), comma: comma))
        case .object(let o):
            guard !o.members.isEmpty else { return lines.append(RawLine(depth: depth, key: k, value: .empty(.object), comma: comma)) }
            lines.append(RawLine(depth: depth, key: k, value: .open(.object), comma: false))
            for (i, m) in o.members.enumerated() {
                appendLines(m.value, key: m.name, depth: depth + 1, comma: i < o.members.count - 1, to: &lines)
            }
            lines.append(RawLine(depth: depth, key: nil, value: .close(.object), comma: comma))
        }
    }
}
