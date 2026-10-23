#if DEBUG
import SwiftUI
import VettIDData
import VettIDItems
import VettIDItemsUI
import VettIDUI

// Sample states stay on one line each.
// swiftlint:disable line_length

/// Debug only: the Vault's sharing screens (what a connection can see, a share rule, what a connection shares) in each of
/// their states with sample data, for the screen catalog and the previews; vettid-android's `ItemsCatalog` `items.sharing…`,
/// `items.rule_…` and `items.shared_…` entries, under their names. Fixed states with actions that do nothing. The release
/// check refuses its strings ("Sharing: rules and grants").
enum ItemsCatalog {
    struct Entry: Identifiable, Sendable {
        let id: String
        let title: String
        let screen: Screen
    }

    enum Screen: Sendable {
        case sharing(ConnectionSharingState)
        case rule(RuleEditState)
        case shared(SharedWithYouState)
    }

    static let now = Date(timeIntervalSince1970: 1_791_384_000)
    private static let day: TimeInterval = 86_400

    private static let passport = ItemSummary(
        itemID: "01JPASSPORT", version: 1, name: "Passport", category: "identity_document", sensitivity: .critical, tags: [], labels: [],
        updatedAt: now
    )

    // One tag per rule (owner decision 2026-10-09); the last names two, as rules made before it may.
    private static let rules = [
        ShareRule(ruleID: "01JRULE1", version: 2, connectionID: "c1", tags: ["medical"], perDay: 20, included: ["i1", "i2"], pending: ["i3"]),
        ShareRule(
            ruleID: "01JRULE2", version: 1, connectionID: "c1", tags: ["travel"], mode: .auto, uses: 5, expiresAt: now.addingTimeInterval(30 * day),
            perHour: 5, included: [passport.itemID]
        ),
        // Overlaps the first: an item tagged both, which asks first (0.23.0: `ask` wins).
        ShareRule(ruleID: "01JRULE3", version: 1, connectionID: "c1", tags: ["insurance"], mode: .auto, uses: 10, included: ["i1"]),
        ShareRule(ruleID: "01JRULE4", version: 1, connectionID: "c1", tags: ["travel", "identity"], match: .all, mode: .auto),
    ]

    /// A connection at the most rules it can have (§10.12 `share_rules_subject`, 64).
    private static let fullRules = (1...64).map { ShareRule(ruleID: "01JFULL\($0)", version: 1, connectionID: "c1", tags: ["tag\($0)"]) }
    private static let tagNames = ["crypto", "identity", "insurance", "medical", "money", "travel"]

    private static let givenGrants = [
        GrantView(grantID: "g1", connectionID: "c1", direction: .given, itemRef: "i1", name: "Allergies", category: "medical", ruleID: "01JRULE1"),
        GrantView(
            grantID: "g2", connectionID: "c1", direction: .given, itemRef: passport.itemID, name: "Passport", category: "identity_document",
            ruleID: "01JRULE2", uses: 5, used: 2
        ),
        GrantView(
            grantID: "g3", connectionID: "c1", direction: .given, itemRef: "i7", name: "Insurance card", category: "insurance", uses: 1,
            expiresAt: now.addingTimeInterval(6 * day)
        ),
    ]

    private static let received = [
        GrantView(grantID: "g5", connectionID: "c1", direction: .received, itemRef: "x1", name: "Practice address", category: "contact"),
        GrantView(
            grantID: "g6", connectionID: "c1", direction: .received, itemRef: "x2", name: "Opening hours", category: "note", uses: 3, used: 1,
            labels: [GrantFieldLabel(fieldID: "f1", label: "Weekdays", kind: "text"), GrantFieldLabel(fieldID: "f2", label: "Saturday", kind: "text")]
        ),
        GrantView(grantID: "g7", connectionID: "c1", direction: .received, itemRef: "x3", name: "Old fax number", category: "contact", state: "revoked"),
    ]

    private static let opened = [
        "g5": SharedContent(
            itemID: "x1", name: "Practice address", category: "contact",
            fields: [
                ItemFieldView(
                    fieldID: "f1", label: "Address", kind: FieldKinds.address,
                    value: .address(AddressValue(street: "Hauptstraße 5", city: "Berlin", postalCode: "10827", country: "DE"))
                ),
                ItemFieldView(fieldID: "f2", label: "Phone", kind: FieldKinds.phone, value: .text("+49 30 1234567")),
            ],
            notes: nil, usesLeft: nil
        ),
    ]

    private static let rulePreview = RulePreview(
        matches: [
            RuleMatch(itemID: "i1", name: "Allergies", category: "medical", sensitivity: .data),
            RuleMatch(itemID: "i2", name: "Blood type", category: "medical", sensitivity: .data),
            RuleMatch(itemID: "i9", name: "Signing key", category: "crypto_wallet", sensitivity: .critical),
        ],
        total: 3
    )

    /// A new `auto` rule for "money": the dry run says what each item does (0.23.0 `outcome`, `ask_rule_id`).
    private static let askWinsPreview = RulePreview(
        matches: [
            RuleMatch(itemID: "i4", name: "Bank account", category: "bank_account", sensitivity: .data, outcome: RuleMatch.outcomeInclude),
            RuleMatch(
                itemID: "i1", name: "Allergies", category: "medical", sensitivity: .data, outcome: RuleMatch.outcomeAsk, askRuleID: "01JRULE1"
            ),
        ],
        total: 2
    )

    static let entries: [Entry] = sharingEntries + ruleEntries + sharedEntries

    private static func sharing(_ edit: (inout ConnectionSharingState) -> Void = { _ in }) -> ConnectionSharingState {
        var s = ConnectionSharingState(connectionID: "c1", connectionName: "Dana Lee")
        s.loading = false
        edit(&s)
        return s
    }

    private static func rule(_ draft: RuleDraft = RuleDraft(connectionID: "c1"), _ edit: (inout RuleEditState) -> Void = { _ in }) -> RuleEditState {
        var s = RuleEditState(draft: draft, connectionName: "Dana Lee")
        s.tags = tagNames
        s.rules = rules
        edit(&s)
        return s
    }

    private static func shared(_ edit: (inout SharedWithYouState) -> Void = { _ in }) -> SharedWithYouState {
        var s = SharedWithYouState(connectionID: "c1", connectionName: "Dana Lee")
        s.loading = false
        edit(&s)
        return s
    }

    private static var sharingEntries: [Entry] {
        [
            Entry(id: "sharing", title: "Sharing: rules and grants", screen: .sharing(sharing {
                $0.rules = rules
                $0.given = givenGrants
                $0.items = [passport.itemID: passport]
            })),
            Entry(id: "sharing_empty", title: "Sharing: nothing yet", screen: .sharing(sharing())),
            Entry(id: "sharing_limit", title: "Sharing: 64 rules", screen: .sharing(sharing { $0.rules = fullRules })),
            Entry(id: "sharing_revoke", title: "Sharing: revoke a grant", screen: .sharing(sharing {
                $0.rules = rules
                $0.given = givenGrants
                $0.confirmRevoke = givenGrants[0]
            })),
        ]
    }

    private static var ruleEntries: [Entry] {
        let money = RuleDraft(connectionID: "c1", tags: ["money"], mode: .auto, perHour: 5, perDay: 20)
        let overlap = RuleDraft(connectionID: "c1", tags: ["medical"])
        let end = now.addingTimeInterval(80 * day)
        return [
            Entry(id: "rule_new", title: "Rule: new", screen: .rule(rule())),
            // One tag per rule (owner decision 2026-10-09): the chosen tag with a gold outline and a check mark.
            Entry(id: "rule_selected", title: "Rule: a tag chosen", screen: .rule(rule(RuleDraft(connectionID: "c1", tags: ["money"])) { $0.dirty = true })),
            // 0.23.0: per hour and per day, and `ask` wins in the dry run.
            Entry(id: "rule_ask_wins", title: "Rule: ask wins in the dry run", screen: .rule(rule(money) {
                $0.perHourText = "5"
                $0.perDayText = "20"
                $0.preview = askWinsPreview
                $0.dirty = true
            })),
            Entry(id: "rule_limits_bad", title: "Rule: limits out of range", screen: .rule(rule(money) {
                $0.perHourText = "5000"
                $0.perDayText = "0"
                $0.dirty = true
            })),
            Entry(id: "rule_read_only", title: "Rule: several tags, read-only", screen: .rule(rule(RuleDraft.of(rules[3])) { $0.readOnly = true })),
            Entry(id: "rule_discard", title: "Rule: discard changes", screen: .rule(rule(money) {
                $0.dirty = true
                $0.confirmDiscard = true
            })),
            Entry(id: "rule_delete", title: "Rule: delete", screen: .rule(rule(RuleDraft.of(rules[1])) {
                $0.expiry = .keep
                $0.confirmDelete = true
            })),
            Entry(id: "rule_edit", title: "Rule: edit", screen: .rule(rule(RuleDraft.of(rules[1])) {
                $0.expiry = .keep
                $0.usesText = "5"
                $0.perHourText = "5"
                $0.preview = RulePreview(
                    matches: [RuleMatch(itemID: passport.itemID, name: "Passport", category: "identity_document", sensitivity: .data)], total: 1
                )
            })),
            // Owner feedback 2026-10-09: rules per tag, each with its own settings.
            Entry(id: "rule_overlap", title: "Rule: overlapping rules", screen: .rule(rule(overlap) { $0.preview = rulePreview })),
            Entry(id: "rule_custom_end", title: "Rule: a custom end", screen: .rule(rule(RuleDraft(connectionID: "c1", tags: ["medical"], expiresAt: end)) {
                $0.expiry = .custom
                $0.usesText = "3"
                $0.preview = rulePreview
            })),
            Entry(id: "rule_custom_date", title: "Rule: custom end, the day", screen: .rule(rule(overlap) {
                $0.preview = rulePreview
                $0.endPicker = .date
            })),
            Entry(id: "rule_custom_time", title: "Rule: custom end, the time", screen: .rule(rule(overlap) {
                $0.preview = rulePreview
                $0.endPicker = .time(RuleEnds.Day(end, zone: .current))
            })),
            Entry(id: "rule_end_bad", title: "Rule: end refused", screen: .rule(rule(overlap) {
                $0.preview = rulePreview
                $0.endInvalid = true
            })),
            Entry(id: "rule_limit", title: "Rule: 64 rules", screen: .rule(rule { $0.rules = fullRules })),
            Entry(id: "rule_limit_error", title: "Rule: vault limit", screen: .rule(rule(overlap) {
                $0.preview = rulePreview
                $0.error = .limit
                $0.limit = VaultLimit("share_rules", max: 512)
            })),
        ]
    }

    private static var sharedEntries: [Entry] {
        [
            Entry(id: "shared_with_you", title: "Shared with you", screen: .shared(shared {
                $0.received = received
                $0.opened = opened
                $0.refused = ["g6": "exhausted"]
            })),
            Entry(id: "shared_rate_limited", title: "Shared with you: try again later", screen: .shared(shared {
                $0.received = received.map { g in
                    var g = g
                    if g.grantID == "g6" {
                        g.perHour = 5
                        g.perDay = 20
                    }
                    return g
                }
                $0.refused = ["g6": "rate_limited"]
                $0.retryAt = ["g6": Date().addingTimeInterval(12 * 60)]
            })),
            Entry(id: "shared_with_you_empty", title: "Shared with you: nothing yet", screen: .shared(shared())),
            Entry(id: "shared_asked", title: "Shared with you: asks made", screen: .shared(shared {
                $0.received = received
                $0.asked = true
                $0.requested = [
                    GrantAsk(
                        requestID: "q1", connectionID: "c1",
                        entries: [GrantAskEntry(kind: "category", ref: "insurance", label: "My insurance card"), GrantAskEntry(kind: "item", ref: "x9")],
                        state: "pending"
                    ),
                    GrantAsk(requestID: "q2", connectionID: "c1", entries: [GrantAskEntry(kind: "category", ref: "contact")], state: "denied"),
                ]
            })),
            Entry(id: "shared_ask", title: "Shared with you: ask for something", screen: .shared(shared {
                $0.received = received
                $0.ask = GrantAskForm(category: "insurance", label: "Insurance card", reason: "Booking the trip")
            })),
            Entry(id: "shared_give_up", title: "Shared with you: remove a grant", screen: .shared(shared {
                $0.received = received
                $0.confirmGiveUp = received[0]
            })),
        ]
    }

    /// The screen for [entry], with actions that do nothing.
    @MainActor @ViewBuilder
    static func screen(_ entry: Entry) -> some View {
        switch entry.screen {
        case .sharing(let s): ConnectionSharingScreen(state: s, actions: ConnectionSharingActions())
        case .rule(let s): RuleEditScreen(state: s, actions: RuleEditActions())
        case .shared(let s): SharedWithYouScreen(state: s, actions: SharedWithYouActions())
        }
    }
}

/// Debug-only: the Vault's sharing screens in each of their states (``ItemsCatalog``). Opened from the screen catalog, or at
/// launch with `-vettid.start items`.
struct ItemsCatalogScreen: View {
    let onBack: @MainActor () -> Void
    @State private var shown: String?

    var body: some View {
        DetailScaffold(onBack: onBack) {
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle("Vault sharing")
                    SettingsGroup {
                        ForEach(ItemsCatalog.entries) { entry in
                            SettingsRow(entry.title) { shown = entry.id }
                                .accessibilityIdentifier("catalog_items_\(entry.id)")
                        }
                    }
                }
            }
        }
        .navigationDestination(item: $shown) { id in
            if let entry = ItemsCatalog.entries.first(where: { $0.id == id }) {
                ItemsCatalog.screen(entry)
                    .overlay(alignment: .topTrailing) {
                        IconButton(.close, label: "Close") { shown = nil }.padding(.horizontal, Spacing.xs)
                    }
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}

// swiftlint:enable line_length

#Preview("Vault sharing") {
    TabView {
        ForEach(ItemsCatalog.entries) { entry in
            ItemsCatalog.screen(entry).tabItem { Text(verbatim: entry.title) }
        }
    }
    .tabViewStyle(.page)
    .vettIDTheme(.dark)
}
#endif
