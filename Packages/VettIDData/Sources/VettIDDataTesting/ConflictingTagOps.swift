import Foundation
import VettIDCrypto
import VettIDData
import VettIDVault

/// TEST ONLY. The registry calls of a vault that lists the same registry every time and answers every `tag.set` with
/// `conflict` (for a ``SharingManager`` driven by the colour keeper). Every other call fails.
public final class ConflictingTagOps: SharingOps, @unchecked Sendable {
    private let lock = NSLock()
    private var setCount = 0
    private let version: Int64
    private let tags: [String]

    /// [tags] listed without a colour, at [version].
    public init(version: Int64, tags: [String]) {
        self.version = version
        self.tags = tags
    }

    /// How many `tag.set` calls were made.
    public var writes: Int { lock.withLock { setCount } }

    private static func refused(_ type: String, _ code: String) -> VaultFailure {
        code == "conflict" ? VaultFailure(.conflict, code: code) : VaultFailure(.notSupported, code: code)
    }

    public func tagList(after: String?) async throws -> TagPage {
        TagPage(version: version, tags: tags.map { TagEntry(tag: $0) })
    }

    public func tagSet(version: Int64, tag: String, color: String?, icon: String?, description: String?) async throws -> Int64 {
        lock.withLock { setCount += 1 }
        throw Self.refused("tag.set", "conflict")
    }

    public func tagMerge(version: Int64, from: [String], into: String, dryRun: Bool) async throws -> JsonObject {
        throw Self.refused("tag.merge", "unsupported_type")
    }

    public func tagDelete(version: Int64, tag: String, dryRun: Bool) async throws -> JsonObject {
        throw Self.refused("tag.delete", "unsupported_type")
    }

    public func ruleList(connectionID: String?, after: String?) async throws -> JsonObject {
        throw Self.refused("share.rule.list", "unsupported_type")
    }

    public func ruleSet(_ body: JsonObject) async throws -> JsonObject { throw Self.refused("share.rule.set", "unsupported_type") }

    public func ruleDelete(_ ruleID: String) async throws { throw Self.refused("share.rule.delete", "unsupported_type") }

    public func grantList() async throws -> JsonObject { throw Self.refused("grant.list", "unsupported_type") }

    public func grantRevoke(_ grantID: String) async throws { throw Self.refused("grant.revoke", "unsupported_type") }

    public func grantRequest(connectionID: String, items: [JsonObject], reason: String?) async throws -> String {
        throw Self.refused("grant.request", "unsupported_type")
    }

    public func grantFetch(_ grantID: String) async throws -> GrantFetched { throw Self.refused("grant.fetch", "unsupported_type") }
}
