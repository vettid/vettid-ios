import Foundation
import VettIDData

/// Sharing with one connection, both ways (VAULT-MESSAGING §10.12): what the member shares with it ([rules] for this
/// connection and the [given] grants in force) and what it shares with the member ([received] grants in force, and the
/// member's [asked] requests still waiting). [loaded] once read; [failed] when the vault could not say (the rest of the
/// detail still shows). Item names are the member's and the connection's own: never printed or mirrored. Mirrors
/// vettid-android `DetailSharing`.
public struct DetailSharing: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var rules: [ShareRule]
    public var given: [GrantView]
    public var received: [GrantView]
    public var asked: [GrantAsk]
    public var loaded: Bool
    public var failed: Bool

    public init(
        rules: [ShareRule] = [], given: [GrantView] = [], received: [GrantView] = [], asked: [GrantAsk] = [], loaded: Bool = false,
        failed: Bool = false
    ) {
        self.rules = rules
        self.given = given
        self.received = received
        self.asked = asked
        self.loaded = loaded
        self.failed = failed
    }

    /// How many items the connection can fetch now (each item once, however many grants name it).
    public var outgoingCount: Int { Set(given.map(\.itemRef)).count }

    /// How many of the connection's items the member can fetch now.
    public var incomingCount: Int { Set(received.map(\.itemRef)).count }

    public var outgoingEmpty: Bool { rules.isEmpty && given.isEmpty }

    public var incomingEmpty: Bool { received.isEmpty }

    /// Each rule's id → the other rules of this connection covering the same tags or items (§10.12).
    public var overlaps: [String: [ShareRule]] { RuleOverlaps.of(rules) }

    /// The connection has the most rules it can have (§10.12 `share_rules_subject`, 64): no new one.
    public var atRuleLimit: Bool { rules.count >= RuleDraft.maxRulesPerSubject }

    public var description: String {
        "DetailSharing(rules: \(rules.count), given: \(given.count), received: \(received.count), asked: \(asked.count), "
            + "loaded: \(loaded), failed: \(failed))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
