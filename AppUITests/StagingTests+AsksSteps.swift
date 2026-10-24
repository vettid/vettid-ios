import XCTest

/// The steps of the sharing and asks tests (``StagingTests/testStagingItemCreate`` and the others of
/// `StagingTests+Asks.swift`). Each returns the state its test reports and never puts a name, label, value or reason in a
/// failure message. Most of the screens' elements carry identifiers; the few that do not are found by their text (English,
/// the only localization) and noted where they are used.
extension StagingTests {
    /// A request of Approvals to decide, as the test describes it.
    struct Approval {
        let peer: String
        /// `grant` or `share`.
        let kind: String
        let approve: Bool
        /// An item the request must name, when set.
        let label: String?
        let include: [String]
        let decline: [String]

        /// The title of the kind's row, as Approvals shows it.
        var title: String { kind == "share" ? "Share with a connection?" : "Request to see your items" }
        /// The identifier prefix of the request's ticks (a share question's items, a grant request's entries).
        var tickPrefix: String { kind == "share" ? "share_item_" : "grant_entry_" }
    }

    /// What one fetch came to.
    struct FetchAnswer {
        /// The item was listed and the fetch asked.
        var found = false
        /// The refusal's kind, nil when the item was shown.
        var refused: String?
        /// What was shown holds the expected text.
        var match = false
        /// The item was shown or refused (the fetch was answered).
        var answered = false
    }

    /// One item row of the Vault list, or a tick of an approval, as one snapshot shows it.
    struct Tick {
        let id: String
        let label: String
        let on: Bool
    }

    static let refusalKinds = ["revoked", "expired", "exhausted", "rate_limited", "unavailable", "ended"]
    /// The label of the one field a test item holds.
    static let fieldLabel = "Value"
    /// Waiting for a screen's list to settle.
    static let settle: TimeInterval = 30

    // MARK: - Reading the screen

    /// Everything [element] shows, its descendants included: labels and values, without the bidi marks.
    @MainActor
    func texts(under element: any XCUIElementSnapshot) -> [String] {
        ordered(under: element).flatMap { [Self.plain($0.label), Self.plain(($0.value as? String) ?? "")] }.filter { !$0.isEmpty }
    }

    /// The first element under the whole app whose identifier is [id], as one snapshot shows it.
    @MainActor
    func snapshotElement(_ app: XCUIApplication, id: String) -> (any XCUIElementSnapshot)? {
        guard let root = try? app.snapshot() else { return nil }
        return ordered(under: root).first { $0.identifier == id }
    }

    /// Whether [label] names [name]: it is the name, or starts with it as one of its parts ("<name>, <note>").
    static func named(_ label: String, _ name: String) -> Bool {
        let l = plain(label)
        return l == name || l.hasPrefix(name + ",")
    }

    /// The identifier of the first element (`<idPrefix><…>`, not one of [excluding]) whose text satisfies [test], looking
    /// at the screen as it is and then scrolling down and back up a few times.
    @MainActor
    func findRow(
        _ app: XCUIApplication, idPrefix: String, excluding: [String] = [], skipping: Set<String> = [], _ test: (String) -> Bool
    ) -> String? {
        for attempt in 0..<10 {
            if attempt > 0 {
                let list = app.scrollViews.firstMatch
                if attempt < 5 { list.swipeUp(velocity: .slow) } else { list.swipeDown(velocity: .slow) }
            }
            guard let root = try? app.snapshot() else { continue }
            let hit = ordered(under: root).first { e in
                e.identifier.hasPrefix(idPrefix) && !skipping.contains(e.identifier) && !excluding.contains { e.identifier.hasPrefix($0) }
                    && test(Self.plain(e.label))
            }
            if let hit { return hit.identifier }
        }
        return nil
    }

    /// Waits for [element], scrolls until it can be tapped; false when it never can.
    @MainActor
    func scrollTo(_ app: XCUIApplication, _ element: XCUIElement, within seconds: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: seconds) else { return false }
        for _ in 0..<6 where !element.isHittable {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        return element.isHittable
    }

    /// The alert's button that confirms ("confirm_button" when the alert carries the identifier, else by its [label]).
    @MainActor
    func confirmAlert(_ app: XCUIApplication, _ label: String) -> Bool {
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 15) else { return false }
        let byId = alert.buttons["confirm_button"]
        let button = byId.exists ? byId : alert.buttons[label]
        guard button.exists else { return false }
        button.tap()
        return true
    }

    /// Leaves an editor with changes: the back arrow and "Discard".
    @MainActor
    func abandonEditor(_ app: XCUIApplication) {
        let back = app.buttons["top_bar_back"].firstMatch
        guard back.exists else { return }
        back.tap()
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 3), alert.buttons["Discard"].exists { alert.buttons["Discard"].tap() }
    }

    // MARK: - Items

    @MainActor
    func createItem(_ app: XCUIApplication, label: String, value: String, tag: String) -> String {
        guard openFromDrawer(app, item: "drawer_items", screen: "items", what: "Vault") else { return "none" }
        tap(anyElement(app, "items_add"))
        guard waitForAny(app, ["items_templates"], timeout: 30) != nil else { return "failed" }
        tap(anyElement(app, "items_template_blank"))
        guard waitForAny(app, ["item_edit"], timeout: 30) != nil else { return "failed" }
        let filled = fillItem(app, label: label, value: value, tag: tag)
        guard filled == "filled" else {
            abandonEditor(app)
            return filled
        }
        tap(anyElement(app, "item_edit_save"))
        guard waitForAny(app, ["item_detail", "item_edit_error"], timeout: Self.network) == "item_detail" else {
            abandonEditor(app)
            return "failed"
        }
        return Self.plain(anyElement(app, "item_name").label) == label ? "created" : "failed"
    }

    /// The new item's form: the name, the one field and the tag; `filled`, `altered` (the keyboard changed what was typed)
    /// or `failed`. The category (Other) and the protection (Data) are the blank item's own; both are checked.
    @MainActor
    private func fillItem(_ app: XCUIApplication, label: String, value: String, tag: String) -> String {
        let name = anyElement(app, "item_edit_name")
        tap(name)
        name.typeText(label)
        guard waitUntil(timeout: 5, { (name.value as? String) == label }) else { return "altered" }
        if let category = anyElement(app, "item_edit_category").value as? String, category != "Other" { return "failed" }
        let data = anyElement(app, "sensitivity_data")
        if data.exists, !data.isSelected { return "failed" }

        let add = anyElement(app, "item_edit_add_field")
        guard reveal(app, add) else { return "failed" }
        add.tap()
        let fieldName = anyElement(app, "item_field_dialog_label")
        guard fieldName.waitForExistence(timeout: 30) else { return "failed" }
        fieldName.tap()
        // Return confirms the dialog.
        fieldName.typeText(Self.fieldLabel + "\n")
        if anyElement(app, "item_field_dialog").waitForExistence(timeout: 3) { tap(anyElement(app, "item_field_dialog_confirm")) }
        let field = anyElement(app, "item_edit_field_value_0")
        guard field.waitForExistence(timeout: 30) else { return "failed" }
        field.tap()
        field.typeText(value)
        guard waitUntil(timeout: 5, { (field.value as? String) == value }) else { return "altered" }

        let tagField = anyElement(app, "item_edit_tag_input")
        guard reveal(app, tagField) else { return "failed" }
        tagField.tap()
        tagField.typeText(tag + "\n")
        return anyElement(app, "item_edit_tags").waitForExistence(timeout: 10) ? "filled" : "failed"
    }

    struct DeleteResult {
        var count = 0
        var done = true
    }

    /// Opens and deletes, one at a time, every item of the Vault whose name starts with [prefix].
    @MainActor
    func deleteItems(_ app: XCUIApplication, prefix: String) -> DeleteResult {
        var result = DeleteResult()
        guard openFromDrawer(app, item: "drawer_items", screen: "items", what: "Vault") else {
            result.done = false
            return result
        }
        _ = waitForAny(app, ["items_list", "items_empty", "items_error", "items_no_match"], timeout: Self.network)
        while result.count < 50 {
            guard let id = findRow(app, idPrefix: "items_row_", { $0.hasPrefix(prefix) }) else { return result }
            guard deleteItem(app, rowID: id, prefix: prefix) else {
                result.done = false
                return result
            }
            result.count += 1
        }
        result.done = false
        return result
    }

    /// The item of the row [rowID] opened (its name must start with [prefix]) and deleted: the pill's "Delete" (no
    /// identifier: found by its label) and the dialog's confirmation.
    @MainActor
    private func deleteItem(_ app: XCUIApplication, rowID: String, prefix: String) -> Bool {
        tap(anyElement(app, rowID))
        guard waitForAny(app, ["item_detail"], timeout: 30) != nil,
              Self.plain(anyElement(app, "item_name").label).hasPrefix(prefix) else {
            tap(app.buttons["top_bar_back"].firstMatch)
            return false
        }
        let delete = app.buttons["Delete"].firstMatch
        guard delete.waitForExistence(timeout: 10) else { return false }
        delete.tap()
        guard confirmAlert(app, "Delete") else { return false }
        return waitUntil(timeout: Self.network) {
            let screen = shown(app)
            return screen["item_detail"] == nil && screen["items"] != nil
        }
    }

    // MARK: - A connection's page

    /// The page of the connection shown as [peer], from Connections; false after the failure.
    @MainActor
    func openConnection(_ app: XCUIApplication, peer: String) -> Bool {
        guard openConnections(app) else { return false }
        var id: String?
        _ = waitUntil(timeout: 45) {
            id = row(app, prefix: "connection_", named: peer, excluding: [])
            return id != nil
        }
        guard let id else {
            fail(app, "No connection shown as VETTID_STAGING_PEER_NAME.")
            return false
        }
        tap(anyElement(app, id))
        guard waitForAny(app, ["connection_detail"], timeout: 30) != nil else {
            fail(app, "The connection's page did not open.")
            return false
        }
        return true
    }

    // MARK: - Rules

    /// The "Share" button of the page's card (a new rule), the tag, the mode, the optional daily limit and "Save rule";
    /// `saved` once the page's card lists the rule, `failed` or `none`.
    @MainActor
    func createRule(_ app: XCUIApplication, tag: String, mode: String, perDay: Int?) -> String {
        let share = anyElement(app, "sharing_out_share")
        guard scrollTo(app, share, within: Self.network), share.isEnabled else { return "none" }
        share.tap()
        guard waitForAny(app, ["rule_edit"], timeout: 30) != nil else { return "failed" }
        // The tags come with the items: a tag no item carries is not offered.
        let chip = anyElement(app, "rule_tag_\(tag)")
        let radio = anyElement(app, "rule_mode_\(mode)")
        guard reveal(app, chip) else { return leaveRule(app) }
        chip.tap()
        guard reveal(app, radio) else { return leaveRule(app) }
        radio.tap()
        guard waitUntil(timeout: 10, { radio.isSelected }) else { return leaveRule(app) }
        if let perDay {
            let field = anyElement(app, "rule_per_day")
            guard reveal(app, field) else { return leaveRule(app) }
            field.tap()
            field.typeText(String(perDay))
        }
        let save = anyElement(app, "rule_save")
        guard waitUntil(timeout: 10, { save.exists && save.isEnabled && save.isHittable }) else { return leaveRule(app) }
        save.tap()
        guard waitUntil(timeout: Self.network, { shown(app)["rule_edit"] == nil }) else { return leaveRule(app) }
        return waitUntil(timeout: Self.settle, { ruleRow(app, tag: tag) != nil }) ? "saved" : "failed"
    }

    /// The rule editor left without saving; `failed`.
    @MainActor
    private func leaveRule(_ app: XCUIApplication) -> String {
        abandonEditor(app)
        return "failed"
    }

    /// The identifier suffix of the page card's rule for [tag], nil if the card lists none.
    @MainActor
    func ruleRow(_ app: XCUIApplication, tag: String) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        let prefix = "sharing_rule_row_"
        let hit = ordered(under: root).first { e in
            e.identifier.hasPrefix(prefix) && texts(under: e).contains { $0.components(separatedBy: ", ").contains(tag) }
        }
        return hit.map { String($0.identifier.dropFirst(prefix.count)) }
    }

    /// The bin of the page card's rule for [tag] and its confirmation; `deleted`, `missing` or `failed`.
    @MainActor
    func deleteRule(_ app: XCUIApplication, tag: String) -> String {
        var suffix: String?
        _ = waitUntil(timeout: Self.settle) {
            suffix = ruleRow(app, tag: tag)
            return suffix != nil
        }
        guard let suffix else { return "missing" }
        let bin = anyElement(app, "sharing_rule_delete_\(suffix)")
        guard scrollTo(app, bin, within: 15) else { return "failed" }
        bin.tap()
        guard confirmAlert(app, "Delete this rule") else { return "failed" }
        return waitUntil(timeout: Self.network, { ruleRow(app, tag: tag) == nil }) ? "deleted" : "failed"
    }

    // MARK: - Asks

    /// "Ask for something" on the page: the optional category, the reason and the label, "Ask"; `sent` once the screen says
    /// so, `failed` or `none`. (The reason is typed first: its field is multi-line, and Return puts the keyboard away from
    /// the label's.)
    @MainActor
    func sendAsk(_ app: XCUIApplication, category: String?, label: String, reason: String) -> String {
        let open = anyElement(app, "sharing_in_ask")
        guard scrollTo(app, open, within: Self.network) else { return "none" }
        open.tap()
        guard waitForAny(app, ["ask_sheet"], timeout: 30) != nil else { return "failed" }
        if let category, category != "Other" {
            tap(anyElement(app, "ask_category"))
            // The menu's entries carry no identifier: found by the category's name.
            let entry = app.buttons[category].firstMatch
            guard entry.waitForExistence(timeout: 10) else { return cancelAsk(app) }
            entry.tap()
        }
        let reasonField = anyElement(app, "ask_reason")
        guard reasonField.waitForExistence(timeout: 10) else { return cancelAsk(app) }
        reasonField.tap()
        reasonField.typeText(reason)
        let labelField = anyElement(app, "ask_label")
        labelField.tap()
        labelField.typeText(label)
        guard waitUntil(timeout: 5, { (labelField.value as? String) == label }) else { return cancelAsk(app) }
        dismissKeyboard(app)
        tap(anyElement(app, "ask_send"))
        guard waitForAny(app, ["ask_sent", "sharing_error"], timeout: Self.network) == "ask_sent" else { return cancelAsk(app) }
        return "sent"
    }

    /// The ask form closed with "Cancel" (a label: the sheet's buttons carry only the confirm's identifier); `failed`.
    @MainActor
    private func cancelAsk(_ app: XCUIApplication) -> String {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        return "failed"
    }

    /// The "Shared by" screen of the connection (its "See what is shared", or "Ask for something" with the form put away when
    /// nothing is shared yet); false after the failure.
    @MainActor
    func openShared(_ app: XCUIApplication, peer: String) -> Bool {
        guard openConnection(app, peer: peer) else { return false }
        let open = anyElement(app, "sharing_in_open")
        if scrollTo(app, open, within: 15) {
            open.tap()
            return waitForAny(app, ["shared_with_you"], timeout: 30) != nil
        }
        let ask = anyElement(app, "sharing_in_ask")
        guard scrollTo(app, ask, within: 15) else { return false }
        ask.tap()
        guard waitForAny(app, ["ask_sheet"], timeout: 30) != nil else { return false }
        _ = cancelAsk(app)
        return waitForAny(app, ["shared_with_you"], timeout: 30) != nil
    }

    /// The state of the ask for [label] ("<label>: waiting|shared|not accepted" on the "Shared by" screen), read again every
    /// 20 seconds until it is not `waiting` or [wait] seconds pass; `missing` if no row names it.
    @MainActor
    func askState(_ app: XCUIApplication, peer: String, label: String, wait: TimeInterval) -> String {
        let states = ["waiting": "waiting", "shared": "shared", "not accepted": "not_accepted"]
        let deadline = Date().addingTimeInterval(wait)
        var state = "missing"
        repeat {
            guard openShared(app, peer: peer) else { return state }
            _ = waitUntil(timeout: 15) { shown(app)["shared_with_you"] != nil }
            sleep(3)
            if let root = try? app.snapshot() {
                let row = ordered(under: root).map { Self.plain($0.label) }.first { $0.hasPrefix(label + ": ") }
                state = row.flatMap { states[String($0.dropFirst(label.count + 2))] } ?? "missing"
            }
            if state == "shared" || state == "not_accepted" || Date() >= deadline { break }
            tap(app.buttons["top_bar_back"].firstMatch)
            sleep(20)
        } while Date() < deadline
        return state
    }
}
