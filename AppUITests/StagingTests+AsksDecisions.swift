import XCTest

/// The steps of the decisions, fetches and revokes of the sharing and asks tests (``StagingTests/testStagingDecide``,
/// ``StagingTests/testStagingFetch``, ``StagingTests/testStagingRevoke``). Like the others they return the state their test
/// reports and put no name, label, value or reason in a failure message.
extension StagingTests {
    // MARK: - Decisions

    /// Approvals: the request [ask] describes, waited for up to [wait] seconds, its ticks set and the decision made.
    @MainActor
    func decideApproval(_ app: XCUIApplication, _ ask: Approval, wait: TimeInterval) -> String {
        guard openFromDrawer(app, item: "drawer_approvals", screen: "approvals_screen", what: "Approvals") else { return "not_opened" }
        let deadline = Date().addingTimeInterval(wait)
        var tried: Set<String> = []
        var reloaded = Date()
        repeat {
            expandBatches(app)
            while let id = findRow(
                app, idPrefix: "approval_", excluding: ["approval_batch_toggle_", "approval_detail"], skipping: tried,
                { $0.contains(ask.title) && $0.contains(ask.peer) }
            ) {
                tried.insert(id)
                tap(anyElement(app, id))
                guard waitForAny(app, ["approval_detail"], timeout: 30) != nil else { return "not_opened" }
                if ask.label.map({ detailNames(app, $0) }) ?? true { return decide(app, ask) }
                tap(app.buttons["top_bar_back"].firstMatch)
                guard waitForAny(app, ["approvals_screen"], timeout: 30) != nil else { return "not_opened" }
            }
            sleep(5)
            if Date().timeIntervalSince(reloaded) > Self.settle, Date() < deadline {
                reloaded = Date()
                guard openFromDrawer(app, item: "drawer_approvals", screen: "approvals_screen", what: "Approvals") else {
                    return "not_opened"
                }
            }
        } while Date() < deadline
        return "missing"
    }

    /// A connection's asks within ten minutes are one row until it is opened ("Show the requests", no label of its own to
    /// match: the button is found by its identifier prefix and its text).
    @MainActor
    private func expandBatches(_ app: XCUIApplication) {
        let toggles = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'approval_batch_toggle_' AND label == 'Show the requests'")
        )
        for _ in 0..<5 {
            let button = toggles.firstMatch
            guard button.exists, button.isHittable else { return }
            button.tap()
        }
    }

    /// Whether the open request names [label] (an item of a share question, an entry of a grant request).
    @MainActor
    private func detailNames(_ app: XCUIApplication, _ label: String) -> Bool {
        guard let root = try? app.snapshot() else { return false }
        return texts(under: root).contains { $0.contains(label) }
    }

    /// The open request: the ticks, then the primary or secondary button; `approved`, `declined` or `not_decided`.
    @MainActor
    private func decide(_ app: XCUIApplication, _ ask: Approval) -> String {
        if ask.approve {
            guard setTicks(app, ask, names: ask.include, on: true), setTicks(app, ask, names: ask.decline, on: false) else {
                tap(app.buttons["top_bar_back"].firstMatch)
                return "not_decided"
            }
            tapPrimary(app)
        } else {
            tap(app.buttons["form_secondary"])
        }
        let left = waitUntil(timeout: Self.network) {
            let screen = shown(app)
            return screen["approval_detail"] == nil && screen["approval_gone"] == nil
        }
        let refused = shown(app)["failure"] != nil
        if !left || refused {
            tap(app.buttons["top_bar_back"].firstMatch)
            return "not_decided"
        }
        return ask.approve ? "approved" : "declined"
    }

    /// The ticks of the open request (a share question's `share_item_<id>`, a grant request's `grant_entry_<i>`).
    @MainActor
    func ticks(_ app: XCUIApplication, _ ask: Approval) -> [Tick] {
        guard let root = try? app.snapshot() else { return [] }
        let all = ordered(under: root).filter { $0.identifier.hasPrefix(ask.tickPrefix) && !$0.identifier.hasPrefix("share_item_note_") }
        return all.compactMap { e in
            // A grant entry is a container around its check box; a share question's item is the button itself.
            let box = ask.kind == "share" ? e : ordered(under: e).first { $0.elementType == .button }
            return box.map { Tick(id: e.identifier, label: Self.plain($0.label), on: $0.isSelected) }
        }
    }

    /// Each of [names] ticked or unticked as [on] says; false when an item is not listed or the tick does not take.
    @MainActor
    private func setTicks(_ app: XCUIApplication, _ ask: Approval, names: [String], on: Bool) -> Bool {
        for name in names {
            guard let tick = ticks(app, ask).first(where: { Self.named($0.label, name) }) else { return false }
            if tick.on == on { continue }
            let target = anyElement(app, tick.id)
            tap(ask.kind == "share" ? target : target.buttons.firstMatch)
            guard waitUntil(timeout: 10, { ticks(app, ask).first { $0.id == tick.id }?.on == on }) else { return false }
        }
        return true
    }

    // MARK: - Fetching

    /// The "Shared by" screen of the connection, the card of [label] waited for up to [wait] seconds (the screen opened
    /// again every 30 seconds), "Show", and the answer.
    @MainActor
    func fetchShared(_ app: XCUIApplication, peer: String, label: String, expected: String?, wait: TimeInterval) -> FetchAnswer {
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            guard openShared(app, peer: peer) else { return FetchAnswer() }
            var card: String?
            _ = waitUntil(timeout: Self.settle) {
                card = receivedCard(app, label: label)
                return card != nil
            }
            if let card { return fetchCard(app, card: card, expected: expected) }
            tap(app.buttons["top_bar_back"].firstMatch)
            sleep(5)
        } while Date() < deadline
        fail(app, "The connection shares no item with the expected name.")
        return FetchAnswer()
    }

    /// The identifier suffix of the received card (`received_<grant id>`) that names [label], nil if none does.
    @MainActor
    func receivedCard(_ app: XCUIApplication, label: String) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        let parts = ["received_label_", "received_fields_", "received_refused_"]
        let hit = ordered(under: root).first { e in
            e.identifier.hasPrefix("received_") && !parts.contains { e.identifier.hasPrefix($0) } && texts(under: e).contains(label)
        }
        return hit.map { String($0.identifier.dropFirst("received_".count)) }
    }

    /// "Show" on the card [card], and what follows: the values shown (held against [expected]) or the refusal.
    @MainActor
    private func fetchCard(_ app: XCUIApplication, card: String, expected: String?) -> FetchAnswer {
        var answer = FetchAnswer(found: true)
        let show = anyElement(app, "fetch_\(card)")
        guard scrollTo(app, show, within: 15) else {
            // No button: the grant is no longer active ("No longer shared").
            answer.refused = "ended"
            answer.answered = true
            return answer
        }
        show.tap()
        _ = waitUntil(timeout: Self.network * 2) { refusal(app, card: card) != nil || !show.exists }
        answer.refused = refusal(app, card: card)
        answer.answered = answer.refused != nil || !show.exists
        if answer.refused == nil, answer.answered, let expected, let root = try? app.snapshot(),
           let element = ordered(under: root).first(where: { $0.identifier == "received_\(card)" }) {
            answer.match = texts(under: element).contains { $0.contains(expected) }
        }
        return answer
    }

    /// Why the card's fetch was refused, in the screen's words: `revoked`, `expired`, `exhausted`, `rate_limited` or
    /// `unavailable`; nil when it was not.
    @MainActor
    func refusal(_ app: XCUIApplication, card: String) -> String? {
        guard let element = snapshotElement(app, id: "received_refused_\(card)") else { return nil }
        let text = Self.plain(element.label)
        let kinds = [
            ("They stopped sharing it", "revoked"), ("The sharing ended", "expired"), ("No fetches are left", "exhausted"),
            ("Opened as often as", "rate_limited"),
        ]
        return kinds.first { text.hasPrefix($0.0) }?.1 ?? "unavailable"
    }

    /// What is wrong with the fetches, in words that carry none of their data; nil when they went as the test said.
    static func fetchProblem(_ answers: [FetchAnswer], times: Int, expected: Bool, refused: String?) -> String? {
        guard answers.count == times, answers.allSatisfy(\.found) else { return "The item was not listed or not fetched." }
        for (i, answer) in answers.enumerated() {
            let last = i == times - 1
            if last, let refused {
                if answer.refused != refused { return "The last fetch was not refused as expected (\(answer.refused ?? "shown"))." }
            } else if !answer.answered || answer.refused != nil || (expected && !answer.match) {
                return "Fetch \(i + 1) did not show the expected text (\(answer.refused ?? (answer.answered ? "no match" : "no answer")))."
            }
        }
        return nil
    }

    // MARK: - Revoking

    /// The page's "Manage" → "What <name> can see": the grant of [label], "Revoke" and its confirmation; `revoked`, `missing`
    /// or `failed`.
    @MainActor
    func revokeGrant(_ app: XCUIApplication, label: String) -> String {
        let manage = anyElement(app, "sharing_out_manage")
        guard scrollTo(app, manage, within: Self.network) else { return "missing" }
        manage.tap()
        guard waitForAny(app, ["connection_sharing"], timeout: 30) != nil else { return "failed" }
        var grant: String?
        _ = waitUntil(timeout: Self.settle) {
            grant = grantRow(app, label: label)
            return grant != nil
        }
        guard let grant else { return "missing" }
        let revoke = anyElement(app, "revoke_\(grant)")
        guard scrollTo(app, revoke, within: 15) else { return "failed" }
        revoke.tap()
        guard confirmAlert(app, "Revoke") else { return "failed" }
        return waitUntil(timeout: Self.network, { grantRow(app, label: label) != grant }) ? "revoked" : "failed"
    }

    /// The identifier suffix of the grant (`grant_<id>`) that names [label], nil if none does.
    @MainActor
    private func grantRow(_ app: XCUIApplication, label: String) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        let hit = ordered(under: root).first { e in
            e.identifier.hasPrefix("grant_") && texts(under: e).contains(label)
        }
        return hit.map { String($0.identifier.dropFirst("grant_".count)) }
    }
}
