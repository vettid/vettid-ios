import XCTest

/// Staging steps for sharing and asks between two phones (VAULT-ITEMS §6, VAULT-MESSAGING §10.12): a tagged test item, a
/// share rule for a connection, "Ask for something", the decisions in Approvals, a fetch of what a connection shares, and
/// the revoking of a grant. The tests in this file are `testStagingItemCreate`, `testStagingItemDelete`,
/// `testStagingRuleCreate`, `testStagingRuleDelete`, `testStagingAsk`, `testStagingAskStatus`, `testStagingDecide`,
/// `testStagingFetch` and `testStagingRevoke`; their steps are in `StagingTests+AsksSteps.swift`.
///
/// Inputs (all through `scripts/staging-ui-test.sh`; the member's own data is never printed and no failure message carries
/// it): `VETTID_STAGING_PEER_NAME` (the connection's shown name), `VETTID_STAGING_ITEM_LABEL` (an item's name; for the
/// delete, the prefix of the names to delete), `VETTID_STAGING_ITEM_VALUE`, `VETTID_STAGING_TAG`, `VETTID_STAGING_RULE_MODE`
/// (`ask` or `auto`), `VETTID_STAGING_RULE_PER_DAY`, `VETTID_STAGING_ASK_REASON`, `VETTID_STAGING_ASK_CATEGORY`,
/// `VETTID_STAGING_ASK_EXPECT` (`shared` or `not_accepted`), `VETTID_STAGING_APPROVAL` (`grant` or `share`),
/// `VETTID_STAGING_DECISION` (`approve` or `decline`), `VETTID_STAGING_SHARE_INCLUDE` and `VETTID_STAGING_SHARE_DECLINE`
/// (item names, `;`-separated), `VETTID_STAGING_GRANT_ITEM` (the item that answers a category entry),
/// `VETTID_STAGING_EXPECT` (the text a fetch must hold), `VETTID_STAGING_FETCH_TIMES`, `VETTID_STAGING_REFUSED` (the
/// refusal the last fetch must meet) and `VETTID_STAGING_WAIT` (seconds).
///
/// Like the other multi-step tests, each goes on to the lock after a failed step (``continueAfterFailure`` is on once the
/// vault is open) and fails once the vault is locked.
extension StagingTests {
    // MARK: - Items

    /// A blank item in the Vault: category Other, protection Data, [VETTID_STAGING_ITEM_LABEL] as its name, one field
    /// ("Value") holding `VETTID_STAGING_ITEM_VALUE` and the tag `VETTID_STAGING_TAG`; saved, and its page shown with the
    /// name. Reported on an `ITEM_STATE:` line (`created`, `altered` when the keyboard changed what was typed (the field
    /// capitalizes each word: give the value so), `failed` or `none`).
    @MainActor
    func testStagingItemCreate() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let label = try Self.input("VETTID_STAGING_ITEM_LABEL")
        let value = try Self.input("VETTID_STAGING_ITEM_VALUE")
        let tag = try Self.input("VETTID_STAGING_TAG")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        let state = createItem(app, label: label, value: value, tag: tag)
        print("ITEM_STATE: \(state)")
        lock(app)
        if state != "created" { fail(app, "The item was not created (\(state)).") }
    }

    /// Every item of the Vault whose name starts with `VETTID_STAGING_ITEM_LABEL`, opened and deleted with its
    /// confirmation. `ITEM_COUNT:` says how many went; `ITEM_STATE:` is `deleted` (one or more), `none` (nothing started
    /// like that; not a failure) or `failed`.
    @MainActor
    func testStagingItemDelete() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let prefix = try Self.input("VETTID_STAGING_ITEM_LABEL")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        let result = deleteItems(app, prefix: prefix)
        let state = !result.done ? "failed" : result.count > 0 ? "deleted" : "none"
        print("ITEM_COUNT: \(result.count)")
        print("ITEM_STATE: \(state)")
        lock(app)
        if state == "failed" { fail(app, "Not every item was deleted.") }
    }

    // MARK: - Rules

    /// The connection's page → "Share" (a new rule): the tag `VETTID_STAGING_TAG`, the mode `VETTID_STAGING_RULE_MODE`
    /// (`ask` by default), the optional `VETTID_STAGING_RULE_PER_DAY`, "Save rule"; then the rule is looked for on the
    /// page's card. Reported on a `RULE_STATE:` line (`saved`, `failed` or `none`).
    @MainActor
    func testStagingRuleCreate() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let tag = try Self.input("VETTID_STAGING_TAG")
        let mode = try Self.choice("VETTID_STAGING_RULE_MODE", ["ask", "auto"], fallback: "ask")
        let perDay = try Self.count("VETTID_STAGING_RULE_PER_DAY")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        var state = "none"
        if openConnection(app, peer: peer) { state = createRule(app, tag: tag, mode: mode, perDay: perDay) }
        print("RULE_STATE: \(state)")
        lock(app)
        if state != "saved" { fail(app, "The rule was not saved (\(state)).") }
    }

    /// The connection's page → the bin of the rule for the tag `VETTID_STAGING_TAG`, confirmed. `RULE_STATE:` is
    /// `deleted`, `missing` (no such rule on the page) or `failed`.
    @MainActor
    func testStagingRuleDelete() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let tag = try Self.input("VETTID_STAGING_TAG")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        var state = "missing"
        if openConnection(app, peer: peer) { state = deleteRule(app, tag: tag) }
        print("RULE_STATE: \(state)")
        lock(app)
        if state != "deleted" { fail(app, "The rule was not deleted (\(state)).") }
    }

    // MARK: - Asks

    /// The connection's page → "Ask for something": the optional category `VETTID_STAGING_ASK_CATEGORY` (a name as the
    /// menu shows it, "Other" by default), the label `VETTID_STAGING_ITEM_LABEL` and the reason
    /// `VETTID_STAGING_ASK_REASON`, "Ask". Reported on an `ASK_STATE:` line (`sent`, `failed` or `none`).
    @MainActor
    func testStagingAsk() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let label = try Self.input("VETTID_STAGING_ITEM_LABEL")
        let reason = try Self.input("VETTID_STAGING_ASK_REASON")
        let category = Self.optional("VETTID_STAGING_ASK_CATEGORY")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        var state = "none"
        if openConnection(app, peer: peer) { state = sendAsk(app, category: category, label: label, reason: reason) }
        print("ASK_STATE: \(state)")
        lock(app)
        if state != "sent" { fail(app, "The ask was not sent (\(state)).") }
    }

    /// How the connection answered the ask for `VETTID_STAGING_ITEM_LABEL`: on the connection's "Shared by" screen the
    /// "Ask for something" list, read (the screen opened again every 20 seconds) until the ask is no longer waiting, for up
    /// to `VETTID_STAGING_WAIT` seconds (60). `ASK_STATE:` is `waiting`, `shared`, `not_accepted`, `missing` or `unopened`
    /// (the screen did not open: the test fails); with `VETTID_STAGING_ASK_EXPECT` set, any other state fails the test.
    @MainActor
    func testStagingAskStatus() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let label = try Self.input("VETTID_STAGING_ITEM_LABEL")
        let expect = try Self.choiceIfSet("VETTID_STAGING_ASK_EXPECT", ["shared", "not_accepted"])
        let limit = try Self.wait(60)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        let state = askState(app, peer: peer, label: label, wait: limit)
        print("ASK_STATE: \(state)")
        lock(app)
        if state == "unopened" { fail(app, "The \"Shared by\" screen did not open.") }
        if let expect, state != expect { fail(app, "The ask is \(state), not \(expect).") }
    }

    // MARK: - Decisions

    /// Approvals → the request from `VETTID_STAGING_PEER_NAME` of the kind `VETTID_STAGING_APPROVAL` (`grant`: "Request to
    /// see your items", or `share`: "Share with a connection?"; `grant` by default), waited for up to
    /// `VETTID_STAGING_WAIT` seconds (120), and, when `VETTID_STAGING_ITEM_LABEL` is set, the one that names that item.
    /// For an approval the items of `VETTID_STAGING_SHARE_INCLUDE` are ticked and those of `VETTID_STAGING_SHARE_DECLINE`
    /// unticked first (the other ticks stay as they are; a grant request's entry is named by its item or by the asked
    /// label), and each category entry to approve is answered with the item named by `VETTID_STAGING_GRANT_ITEM` (the first
    /// offered by default), which ticks it; then `VETTID_STAGING_DECISION` (`approve`: the primary button,
    /// `decline`: "Deny" or "Do not share"). Reported on a `SHARE_STATE:` line (`approved`, `declined`, `not_decided`,
    /// `not_opened` or `missing`).
    @MainActor
    func testStagingDecide() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let kind = try Self.choice("VETTID_STAGING_APPROVAL", ["grant", "share"], fallback: "grant")
        let decision = try Self.required("VETTID_STAGING_DECISION", ["approve", "decline"])
        let ask = Approval(
            peer: peer, kind: kind, approve: decision == "approve", label: Self.optional("VETTID_STAGING_ITEM_LABEL"),
            include: Self.list("VETTID_STAGING_SHARE_INCLUDE"), decline: Self.list("VETTID_STAGING_SHARE_DECLINE"),
            answer: Self.optional("VETTID_STAGING_GRANT_ITEM")
        )
        let limit = try Self.wait(120)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        let state = decideApproval(app, ask, wait: limit)
        print("SHARE_STATE: \(state)")
        lock(app)
        if state != (ask.approve ? "approved" : "declined") { fail(app, "The request was not decided as asked (\(state)).") }
    }

    // MARK: - Fetching and revoking

    /// What the connection shares with the member, fetched: the connection's page → the "Shared by" screen (waited for up to
    /// `VETTID_STAGING_WAIT` seconds, 120, until the item `VETTID_STAGING_ITEM_LABEL` is listed), "Show", the answer. Done
    /// `VETTID_STAGING_FETCH_TIMES` times (1), the screen left and opened again for each. Each fetch prints
    /// `FETCH_MATCH: yes|no` (does what is shown hold `VETTID_STAGING_EXPECT`; only when that is set) and
    /// `FETCH_REFUSED: none|revoked|expired|exhausted|rate_limited|unavailable|ended`, never the text. Without
    /// `VETTID_STAGING_REFUSED` every fetch must be answered with the item (and a match); with it, the last one must be
    /// refused so.
    @MainActor
    func testStagingFetch() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let label = try Self.input("VETTID_STAGING_ITEM_LABEL")
        let expected = Self.optional("VETTID_STAGING_EXPECT")
        let times = try Self.count("VETTID_STAGING_FETCH_TIMES") ?? 1
        let refused = try Self.choiceIfSet("VETTID_STAGING_REFUSED", Self.refusalKinds)
        let limit = try Self.wait(120)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        var answers: [FetchAnswer] = []
        for _ in 0..<times {
            let answer = fetchShared(app, peer: peer, label: label, expected: expected, wait: limit)
            answers.append(answer)
            if expected != nil { print("FETCH_MATCH: \(answer.match ? "yes" : "no")") }
            print("FETCH_REFUSED: \(answer.refused ?? "none")")
            if !answer.found { break }
        }
        lock(app)
        let problem = Self.fetchProblem(answers, times: times, expected: expected != nil, refused: refused)
        if let problem { fail(app, problem) }
    }

    /// The connection's page → "Manage" → the grant of the item `VETTID_STAGING_ITEM_LABEL` given to the connection →
    /// "Revoke", confirmed. `GRANT_STATE:` is `revoked`, `missing` (no such grant) or `failed`.
    @MainActor
    func testStagingRevoke() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let label = try Self.input("VETTID_STAGING_ITEM_LABEL")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        var state = "missing"
        if openConnection(app, peer: peer) { state = revokeGrant(app, label: label) }
        print("GRANT_STATE: \(state)")
        lock(app)
        if state != "revoked" { fail(app, "The grant was not revoked (\(state)).") }
    }

    // MARK: - Inputs

    /// The optional input [name], nil when not set.
    static func optional(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return value
    }

    /// The optional `;`-separated list [name], each part trimmed.
    static func list(_ name: String) -> [String] {
        (optional(name) ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The optional input [name], one of [allowed] (lower case); [fallback] without it.
    static func choice(_ name: String, _ allowed: [String], fallback: String) throws -> String {
        try choiceIfSet(name, allowed) ?? fallback
    }

    /// The optional input [name], one of [allowed] (lower case); nil when not set.
    static func choiceIfSet(_ name: String, _ allowed: [String]) throws -> String? {
        guard let value = optional(name)?.lowercased() else { return nil }
        guard allowed.contains(value) else { throw AsksInputError.notOneOf(name, allowed) }
        return value
    }

    /// The input [name], one of [allowed] (lower case); the test is skipped without it.
    static func required(_ name: String, _ allowed: [String]) throws -> String {
        _ = try input(name)
        return try choiceIfSet(name, allowed) ?? ""
    }

    /// The optional positive whole number [name]; nil when not set.
    static func count(_ name: String) throws -> Int? {
        guard let value = optional(name) else { return nil }
        guard let n = Int(value), n > 0, n <= 86_400 else { throw AsksInputError.notCount(name) }
        return n
    }

    enum AsksInputError: Error, CustomStringConvertible {
        case notOneOf(String, [String])
        case notCount(String)

        var description: String {
            switch self {
            case let .notOneOf(name, allowed): "\(name) is not one of \(allowed.joined(separator: ", "))"
            case let .notCount(name): "\(name) is not a positive whole number"
            }
        }
    }
}
