import XCTest

/// Staging steps for several members at once (connecting by link, rotating the keys, messaging every connection): an
/// invitation link for another member to paste (``testStagingInvite``), link requests approved by their safety codes
/// (``testStagingApproveRequest``), the credential key rotated (``testStagingRotate``), a message to every connection
/// (``testStagingSendAll``), a wait for one message (``testStagingWaitMessage``), and screenshots without changing
/// anything (``testStagingLook``, ``testStagingCheck``). After the unlock every test goes on to the lock whatever a
/// step found (a step's failure is recorded, not the end), and a failed step fails the test once the vault is locked.
extension StagingTests {
    /// Now, in UTC (ISO 8601), for the texts the tests send.
    static func utcNow() -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    /// `VETTID_STAGING_WAIT`: positive seconds, optional; [fallback] without it. Read before the unlock.
    static func wait(_ fallback: TimeInterval) throws -> TimeInterval { try seconds("VETTID_STAGING_WAIT", fallback: fallback) }

    /// A remote invitation (24 hours), so that the other member can paste it later.
    static let remoteTtl = "ttl_86400"

    @MainActor
    func testStagingInvite() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        var link: String?
        if openConnections(app) {
            tap(anyElement(app, "add_connection"))
            tap(anyElement(app, "add_invite"))
            if waitForAny(app, ["invite_choose"], timeout: 30) != nil {
                tap(anyElement(app, Self.remoteTtl))
                tapPrimary(app)
                if waitForAny(app, ["invite_showing"], timeout: Self.network) != nil { link = inviteLink(app) }
            }
        }
        print("INVITE_LINK: \(link ?? "none")")
        // The invitation stays open on the vault: the other member's request is approved later (testStagingApproveRequest).
        lock(app)
        if link == nil { fail(app, "No invitation link was read.") }
    }

    @MainActor
    func testStagingRotate() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        var end: String?
        openSettings(app)
        let credentialRow = app.buttons["credential_row"]
        if reveal(app, credentialRow) {
            credentialRow.tap()
            expect(app, "credential", timeout: 30)
            let rotateRow = anyElement(app, "rotate_row")
            let field = app.secureTextFields["rotate_password"]
            let opened = reveal(app, rotateRow) && {
                rotateRow.tap()
                return field.waitForExistence(timeout: 30)
            }()
            if opened {
                field.tap()
                field.typeText(password)
                tapPrimary(app)
                end = waitForAny(app, ["rotate_done", "error"], timeout: Self.network * 2)
                failOnSavePassword(app)
                if end == "rotate_done" { tapPrimary(app) }
            }
        }
        print("ROTATE_STATE: \(end == "rotate_done" ? "done" : end == "error" ? "failed" : "none")")
        lock(app)
        if end != "rotate_done" { fail(app, "The rotation did not finish.") }
    }

    /// The invitation's link as its own element shows it (`invite_link`), nil if it cannot be read.
    @MainActor
    func inviteLink(_ app: XCUIApplication) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        guard let box = ordered(under: root).first(where: { $0.identifier == "invite_link" }) else { return nil }
        for e in [box] + ordered(under: box) {
            for text in [e.label, (e.value as? String) ?? ""] where text.hasPrefix("https://") {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// The incoming bubbles from [peer] that show [text], as read (each with its time): a wait counts only one that is
    /// not among those it began with, whether or not older ones are still drawn.
    @MainActor
    func incomingBubbles(_ app: XCUIApplication, peer: String, text: String) -> Set<String> {
        guard let root = try? app.snapshot() else { return [] }
        return Set(ordered(under: root).map { Self.plain($0.label) }.filter { $0.hasPrefix(peer + ": ") && $0.contains(text) })
    }
}

extension StagingTests {
    /// A look without changing anything: Connections (after `VETTID_STAGING_WAIT` seconds, 10 by default, for what the
    /// vault collects), then Approvals, as screenshots kept in the result bundle. Then the vault is locked.
    @MainActor
    func testStagingLook() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let wait = try Self.wait(10)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        if openConnections(app) {
            Thread.sleep(forTimeInterval: wait)
            snap(app, "look-connections")
            app.swipeUp(velocity: .slow)
            snap(app, "look-connections-more")
        }
        if openFromDrawer(app, item: "drawer_approvals", screen: "approvals_screen", what: "Approvals") {
            sleep(5)
            snap(app, "look-approvals")
        }
        lock(app)
    }

    @MainActor
    func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}

extension StagingTests {
    /// Link requests from Approvals, incoming or the member's own (both members approve, VAULT-MESSAGING §6.4): for each
    /// safety code of `VETTID_STAGING_SAFETY_CODE` (comma-separated, as the other phone shows them), the row with exactly
    /// that code that still waits for this member, opened and approved (with the password if asked); each reported on a
    /// `CONNECT_STATE:` line (`approved`, `not_approved`, `not_opened` or `missing`). Then the vault is locked.
    @MainActor
    func testStagingApproveRequest() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let codes = try Self.input("VETTID_STAGING_SAFETY_CODE").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        var states: [String] = []
        for code in codes {
            guard openFromDrawer(app, item: "drawer_approvals", screen: "approvals_screen", what: "Approvals") else { break }
            var rowID: String?
            _ = waitUntil(timeout: Self.network) {
                guard let root = try? app.snapshot() else { return false }
                rowID = ordered(under: root).first { e in
                    e.identifier.hasPrefix("approval_") && Self.safetyCode(inRow: e.label) == code && !e.label.contains("waiting for")
                }?.identifier
                return rowID != nil
            }
            let state = approve(app, row: rowID, password: password)
            states.append(state)
            print("CONNECT_STATE: \(state)")
        }
        lock(app)
        if states.count != codes.count || states.contains(where: { $0 != "approved" }) {
            fail(app, "Not every request was approved: \(states.joined(separator: ", ")).")
        }
    }

    /// The request [row] opened and approved: `approved`, `not_approved`, `not_opened` or `missing`.
    @MainActor
    private func approve(_ app: XCUIApplication, row: String?, password: String) -> String {
        guard let row else { return "missing" }
        tap(anyElement(app, row))
        guard waitForAny(app, ["approval_detail"], timeout: 30) != nil else { return "not_opened" }
        let field = app.secureTextFields["approval_password"]
        if field.waitForExistence(timeout: 3) {
            field.tap()
            field.typeText(password)
        }
        tapPrimary(app)
        let left = waitUntil(timeout: Self.network) { shown(app)["approval_detail"] == nil }
        let failure = shown(app)["failure"]
        failOnSavePassword(app)
        if !left { tap(app.buttons["top_bar_back"].firstMatch) }
        return left && failure == nil ? "approved" : "not_approved"
    }

    /// The six-digit safety code a request row shows ("… · code 123456 · …"), nil if none.
    static func safetyCode(inRow label: String) -> String? {
        guard let r = label.range(of: #"code (\d{6})(?!\d)"#, options: .regularExpression) else { return nil }
        return String(label[r].dropFirst("code ".count))
    }
}

extension StagingTests {
    /// The vault kept open in the conversation with `VETTID_STAGING_PEER_NAME` until a new message from it shows
    /// `VETTID_STAGING_EXPECT` (one already there when the wait began does not count), for up to `VETTID_STAGING_WAIT`
    /// seconds (600 by default); reported on a `MESSAGE_RECEIVED:` line, with a screenshot of the conversation. Then the
    /// vault is locked.
    @MainActor
    func testStagingWaitMessage() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let expected = try Self.input("VETTID_STAGING_EXPECT")
        let limit = try Self.wait(600)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        var received = false
        if openConversation(app, peer: peer) {
            let before = incomingBubbles(app, peer: peer, text: expected)
            let deadline = Date().addingTimeInterval(limit)
            while !received, Date() < deadline {
                received = waitUntil(timeout: max(min(Self.reopenEvery, deadline.timeIntervalSinceNow), 0)) {
                    !incomingBubbles(app, peer: peer, text: expected).subtracting(before).isEmpty
                }
                if !received, Date() < deadline {
                    tap(app.buttons["top_bar_back"].firstMatch)
                    guard waitForAny(app, ["messages_screen", "new_message_screen"], timeout: 30) != nil,
                          openConversation(app, peer: peer) else { break }
                }
            }
        }
        print("MESSAGE_RECEIVED: \(received ? "yes" : "no")")
        snap(app, "wait-conversation")
        lock(app)
        if !received { fail(app, "No new message from the connection with the expected text.") }
    }
}

extension StagingTests {
    /// A look after a step: the unlock, Connections (after a wait for what the vault collects), the conversation with
    /// `VETTID_STAGING_PEER_NAME`, Connections again, then History last (screenshots kept in the result bundle). Nothing
    /// is tapped beyond navigation. Then the vault is locked.
    @MainActor
    func testStagingCheck() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        if openConnections(app) {
            sleep(30)
            snap(app, "check-1-connections")
        }
        if openConversation(app, peer: peer) {
            sleep(5)
            snap(app, "check-2-conversation")
        }
        if openConnections(app) { snap(app, "check-3-connections") }
        if openFromDrawer(app, item: "drawer_history", screen: "history_screen", what: "History") {
            sleep(5)
            snap(app, "check-4-history")
        }
        lock(app)
    }
}

extension StagingTests {
    /// To each connection of `VETTID_STAGING_PEER_NAME` ("Name=label;Name=label", the shown names and the short labels
    /// used in the texts), "`VETTID_STAGING_MESSAGE` to <label> <UTC>" sent and followed to Delivered (a
    /// `MESSAGE_STATE:` line each, in order); then, for up to `VETTID_STAGING_WAIT` seconds (300), each conversation
    /// checked for a new incoming message holding `VETTID_STAGING_EXPECT` (a `MESSAGE_RECEIVED:` line each, in order),
    /// with screenshots. Then the vault is locked; a message not delivered or not received fails the test.
    @MainActor
    func testStagingSendAll() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peers = try Self.input("VETTID_STAGING_PEER_NAME").split(separator: ";").map { pair in
            let p = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return (name: p[0], label: p.count > 1 ? p[1] : p[0])
        }
        let prefix = try Self.input("VETTID_STAGING_MESSAGE")
        let expected = try Self.input("VETTID_STAGING_EXPECT")
        let limit = try Self.wait(300)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        var sent: [String] = []
        var before: [Set<String>] = []
        for peer in peers {
            guard openConversation(app, peer: peer.name) else {
                sent.append("none")
                before.append([])
                print("MESSAGE_STATE: none")
                continue
            }
            before.append(incomingBubbles(app, peer: peer.name, text: expected))
            let state = send(app, "\(prefix) to \(peer.label) \(Self.utcNow().suffix(9).dropLast())")
            sent.append(state)
            print("MESSAGE_STATE: \(state)")
            tap(app.buttons["top_bar_back"].firstMatch)
        }
        let deadline = Date().addingTimeInterval(limit)
        var got = Array(repeating: false, count: peers.count)
        while got.contains(false), Date() < deadline {
            for (i, peer) in peers.enumerated() where !got[i] && Date() < deadline {
                if openConversation(app, peer: peer.name) {
                    got[i] = waitUntil(timeout: 5) { !incomingBubbles(app, peer: peer.name, text: expected).subtracting(before[i]).isEmpty }
                    if got[i] || Date() >= deadline { snap(app, "sendall-\(peer.label)") }
                    tap(app.buttons["top_bar_back"].firstMatch)
                }
            }
        }
        for g in got { print("MESSAGE_RECEIVED: \(g ? "yes" : "no")") }
        lock(app)
        if sent.contains(where: { $0 != "delivered" && $0 != "read" }) || got.contains(false) {
            fail(app, "Not every message was delivered and received.")
        }
    }

    /// [text] sent in the open conversation, as testStagingMessageSend does (the reply field must hold it as given), and
    /// followed until Delivered: its last state (`sent`, `delivered`, `read`) or `none`.
    @MainActor
    private func send(_ app: XCUIApplication, _ text: String) -> String {
        let composer = anyElement(app, "composer")
        guard composer.waitForExistence(timeout: 30) else { return "none" }
        composer.tap()
        composer.typeText(text)
        guard waitUntil(timeout: 5, { (composer.value as? String) == text }) else { return "none" }
        let send = app.buttons["send"]
        guard waitUntil(timeout: 10, { send.exists && send.isEnabled && send.isHittable }) else { return "none" }
        send.tap()
        var state: String?
        _ = waitUntil(timeout: Self.delivery) {
            state = outgoingStates(app, text: text).last
            return state == "delivered" || state == "read"
        }
        return state ?? "none"
    }
}
