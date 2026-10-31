import Foundation
import VettIDCrypto

/// The app's work with the public votes site for the vault (VAULT-MESSAGING 0.81.6 §10.19.8 `vote.site.sync`;
/// ANDROID-PLAN 0.1.107): what it fetches, and the requests it makes of it within the per-call limits. The vault decides
/// everything; the app hands over public documents, with no time of its own. Mirrors vettid-android `VoteSync`.
public enum VoteSync {
    /// §5.5: a padded plaintext over this travels as a claim-check blob to the app's own vault; at or under, inline.
    public static let inlineMax = Padding.maxPadded
    /// The encoded request body, at most (`attachment_max_bytes`, §10.5.1). Never sent over.
    public static let bodyMax = 8_257_532
    public static let maxLists = 8
    public static let maxEntries = 8
    /// One list over this size goes in a call of its own.
    public static let bigList = 1_048_576
    /// New (not held) proposals whose documents are read in one run (chosen; not in the spec: as vettid-android).
    public static let maxNew = 24
    /// The most extensions the site holds for a proposal (VOTES-SITE §4).
    public static let maxExtensions = 24

    public static let type = "vote.site.sync"

    /// Whether a request body travels inline: §5.5 caps the padded **inner plaintext** (the body inside the inner
    /// envelope with `v`, `id`, `type`, `ts`, `seq`, padded to its bucket), not the body alone. Measured through the real
    /// encoder with the longest `seq`; over the cap it goes as a claim-check blob.
    public static func fitsInline(_ body: [UInt8], type: String = type) -> Bool {
        let inner = Inner(id: Ulid.new(), type: type, ts: Date(), seq: StrictJson.maxSafeInteger, body: body)
        guard let plain = try? inner.marshal(.session) else { return false }
        return (try? Padding.paddedLen(plain.count)) != nil
    }

    /// A service list as the site serves it: the exact bytes, its detached signature (64 raw bytes) and its version.
    public struct ServedList: Sendable, Equatable {
        public let doc: [UInt8]
        public let sig: [UInt8]
        public let version: Int64

        public init(doc: [UInt8], sig: [UInt8], version: Int64) {
            self.doc = doc
            self.sig = sig
            self.version = version
        }

        /// What the vault takes of a list at all: a document and a signature of exactly 64 bytes. Anything else makes it
        /// refuse the whole call, so such a list is never sent (VAULT-MESSAGING §10.19.8).
        public var sendable: Bool { !doc.isEmpty && sig.count == VoteSiteLimits.sigLength }
    }

    /// `services.json`'s `version`; nil when the document does not read (the vault judges it, so it is still sent).
    public static func versionOf(_ doc: [UInt8]) -> Int64? {
        guard let o = try? StrictJson.parseObject(doc), let v = try? o.uint("version", min: 0, max: StrictJson.maxSafeInteger)
        else { return nil }
        return Int64(v)
    }

    /// The services part of a run.
    public enum ListPlan: Sendable, Equatable {
        case nothing
        case confirm(version: Int64, sha256: String)
        /// The versions to hand over, oldest first.
        case send([ServedList])
    }

    /// Chooses what to do with the served list [current] (the vault holds [heldVersion] with [heldSha256], or nothing): the
    /// same bytes are only confirmed (`services_confirm`), a newer list goes after the versions between, oldest first
    /// ([between] are the versions in order after the held one that the site already serves), an older one is not sent.
    public static func planLists(
        _ current: ServedList, heldVersion: Int64?, heldSha256: String?, between: [ServedList]
    ) -> ListPlan {
        // A vault with no list takes any that verifies.
        guard let held = heldVersion else { return .send([current]) }
        if let heldSha256, Base64s.encodeStd(Bytes.sha256(current.doc)) == heldSha256 {
            return .confirm(version: current.version, sha256: heldSha256)
        }
        if current.version < held { return .nothing }
        if current.version == held { return .send([current]) }
        // Each version chains to the one before: all that are missing, in order, then the current one.
        if Int64(between.count) == current.version - held - 1 { return .send(between + [current]) }
        // A copy the site does not serve yet (404): the contiguous ones go, the rest at the next run.
        return between.isEmpty ? .nothing : .send(between)
    }

    /// `{doc, sig}` of a list.
    static func listJson(_ l: ServedList) -> String {
        JsonBuilder().base64("doc", l.doc).base64("sig", l.sig).build()
    }

    /// The calls that carry [lists] (oldest first), as the lists each call holds: at most ``maxLists`` each, one alone when
    /// it is over ``bigList``, and none over ``bodyMax`` once encoded (chosen; not in the spec: eight lists of 1 MiB each
    /// would pass it as base64). A list the vault would refuse (``ServedList/sendable``) or that alone would pass
    /// ``bodyMax``, and the later ones, which cannot chain without it, are not sent.
    public static func listBatches(_ lists: [ServedList]) -> [[ServedList]] {
        var calls: [[ServedList]] = []
        var current: [ServedList] = []
        var size = listsEnvelope
        for l in lists {
            let n = encodedSize(l) + 1
            if !l.sendable || l.doc.count > bodyMax || n + listsEnvelope > bodyMax { break }
            let big = l.doc.count > bigList
            let full = current.count >= maxLists || current.contains { $0.doc.count > bigList } || size + n > bodyMax
            if !current.isEmpty, big || full {
                calls.append(current)
                current = []
                size = listsEnvelope
            }
            current.append(l)
            size += n
        }
        if !current.isEmpty { calls.append(current) }
        return calls
    }

    /// The body of one call of ``listBatches(_:)``.
    public static func listBody(_ batch: [ServedList]) -> [UInt8] {
        JsonBuilder().raw("services", JsonBuilder.array(batch.map(listJson))).bytes()
    }

    /// All the bodies at once (the tests); the runner builds one at a time.
    public static func listCalls(_ lists: [ServedList]) -> [[UInt8]] { listBatches(lists).map(listBody) }

    private static let listsEnvelope = 15 // {"services":[]}

    /// `{"doc":"…","sig":"…"}` as encoded.
    private static func encodedSize(_ l: ServedList) -> Int { 4 * ((l.doc.count + 2) / 3) + 4 * ((l.sig.count + 2) / 3) + 20 }

    public static func confirmCall(version: Int64, sha256: String) -> [UInt8] {
        let c = JsonBuilder().uint("version", UInt64(max(version, 0))).string("sha256", sha256)
        return JsonBuilder().raw("services_confirm", c.build()).bytes()
    }

    /// One proposal's documents as read from the site.
    public enum Document: Sendable, Equatable {
        case found(proposal: [UInt8], proposalSig: [UInt8]?, bundle: String?, extensions: [Extension])
        case absent
        case unreachable
    }

    /// An extension's documents; [bundle] is the compact JSON object the site served, nil when it did not read.
    public struct Extension: Sendable, Equatable {
        public let doc: [UInt8]
        public let sig: [UInt8]?
        public let bundle: String?

        public init(_ doc: [UInt8], sig: [UInt8]?, bundle: String?) {
            self.doc = doc
            self.sig = sig
            self.bundle = bundle
        }
    }

    /// `{proposal_id, index?, document}` with no time (the vault stamps an `absent` itself). [index] is the index element's
    /// compact JSON as the site served it.
    public static func entryJson(_ proposalID: String, index: String?, _ d: Document) -> String {
        let e = JsonBuilder().string("proposal_id", proposalID)
        if let index { e.raw("index", index) }
        let doc = JsonBuilder()
        switch d {
        case .absent: doc.string("status", "absent")
        case .unreachable: doc.string("status", "unreachable")
        case let .found(proposal, sig, bundle, extensions):
            doc.string("status", "found").base64("proposal", proposal)
            if let sig { doc.base64("proposal_sig", sig) }
            if let bundle { doc.raw("bundle", bundle) }
            let xs = extensions.map { x in
                let b = JsonBuilder().base64("extension", x.doc)
                if let s = x.sig { b.base64("extension_sig", s) }
                if let bundle = x.bundle { b.raw("bundle", bundle) }
                return b.build()
            }
            doc.raw("extensions", JsonBuilder.array(xs))
        }
        return e.raw("document", doc.build()).build()
    }

    private static let envelope = 14 // {"entries":[]}

    /// The bodies that carry [entries]: at most ``maxEntries`` each and each within ``bodyMax``. An entry that alone
    /// would pass the limit is not sent (the vault would refuse the call), and the others are.
    public static func entryCalls(_ entries: [String]) -> [[UInt8]] {
        var calls: [[UInt8]] = []
        var batch: [String] = []
        var size = envelope
        func flush() {
            if !batch.isEmpty { calls.append(JsonBuilder().raw("entries", JsonBuilder.array(batch)).bytes()) }
            batch = []
            size = envelope
        }
        for e in entries {
            let n = e.utf8.count + 1
            if n + envelope > bodyMax { continue }
            if batch.count >= maxEntries || size + n > bodyMax { flush() }
            batch.append(e)
            size += n
        }
        flush()
        return calls
    }

    /// Where the site's own JSON sits in a `vote.site.sync` (or `vote.results.submit`) body, counting the body as level 1:
    /// the vault parses the whole request strictly with a nesting limit of 32 for all of it, so a value at level L may be
    /// `32 - L + 1` deep (VAULT-MESSAGING 0.81.6 §10.19.8 "Strict JSON").
    public enum Level {
        /// `{entries: [ {index: …} ]}`: body, `entries`, the entry, `index`.
        public static let index = 4
        /// … the entry, `document`, `bundle`.
        public static let proposalBundle = 5
        /// … `document`, `extensions`, the extension, `bundle`.
        public static let extensionBundle = 7
        /// `vote.results.submit`: the body, `bundle` (the erratum does not name this one; the vault parses that request
        /// the same way).
        public static let resultsBundle = 2
    }

    /// A site JSON document that is one object, as compact JSON, parsed strictly (valid UTF-8, no duplicate member name at
    /// any depth) and deep enough to sit at [level] of the request; nil when it is not (VAULT-MESSAGING 0.81.6 §10.19.8:
    /// "not an object").
    public static func compactObject(_ bytes: [UInt8], level: Int) -> String? {
        guard let c = try? StrictJson.compactObject(bytes, maxDepth: StrictJson.maxDepth - level + 1) else { return nil }
        return String(bytes: c, encoding: .utf8)
    }

    /// The index's elements (`index.json` is an array) with their `proposal_id` and as compact JSON objects; an unreadable
    /// index yields none. Each element is read on its own, strictly, so that one bad element leaves out only itself:
    /// - an element that is no strict object, or whose `proposal_id` is not a valid proposal id, is not sent at all, nor
    ///   an entry for it (0.81.6; the id also becomes part of a path on the site);
    /// - an element the vault would refuse the call for (a `service_id` that is no string, or deeper than the request
    ///   allows at its place) is kept for its id, with no `json`: the entry goes without `index`.
    public static func indexOf(_ bytes: [UInt8]) -> [(proposalID: String, json: String?)] {
        guard let elements = arrayElements(bytes) else { return [] }
        return elements.compactMap { raw in
            guard let o = try? StrictJson.parseObject(raw), let id = try? o.string("proposal_id"), Ulid.isValid(id) else {
                return nil
            }
            let serviceIDReads: Bool
            do { _ = try o.optString("service_id"); serviceIDReads = true } catch { serviceIDReads = false }
            return (id, serviceIDReads ? compactObject(raw, level: Level.index) : nil)
        }
    }

    // swiftlint:disable cyclomatic_complexity
    /// The top-level elements of the JSON array [bytes] as byte slices, found by a scan that parses nothing (so that a
    /// hostile element cannot cost the others); nil when [bytes] is not one array.
    static func arrayElements(_ bytes: [UInt8]) -> [[UInt8]]? {
        var i = 0
        func skipSpace() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }
        skipSpace()
        guard i < bytes.count, bytes[i] == UInt8(ascii: "[") else { return nil }
        i += 1
        var out: [[UInt8]] = []
        var depth = 0
        var start = i
        var inString = false
        var escaped = false
        var closed = false
        while i < bytes.count, !closed {
            let c = bytes[i]
            if inString {
                if escaped { escaped = false } else if c == 0x5C { escaped = true } else if c == 0x22 { inString = false }
            } else {
                switch c {
                case 0x22: inString = true
                case UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
                case UInt8(ascii: "}"): depth -= 1
                case UInt8(ascii: "]"):
                    if depth == 0 {
                        closed = true
                        out.append(Array(bytes[start..<i]))
                    } else {
                        depth -= 1
                    }
                case UInt8(ascii: ","):
                    if depth == 0 {
                        out.append(Array(bytes[start..<i]))
                        start = i + 1
                    }
                default: break
                }
            }
            if depth < 0 { return nil }
            i += 1
        }
        guard closed else { return nil }
        skipSpace()
        guard i == bytes.count else { return nil }
        // An empty array has no element; an empty one between commas is no element either.
        return out.filter { !$0.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) } }
    }
    // swiftlint:enable cyclomatic_complexity

    /// An index element's `extended` count when it reads.
    public static func extendedOf(_ index: String?) -> Int? {
        guard let index, let o = try? StrictJson.parseObject(index),
              let n = try? o.uint("extended", min: 0, max: UInt64(Int32.max))
        else { return nil }
        return Int(n)
    }
}
