import XCTest

/// The staging scale test's iPhone steps: an invitation link made on this phone for another member to paste
/// (``testStagingInvite``, reported on an `INVITE_LINK:` line), and the credential key rotated with the password
/// (``testStagingRotate``, VAULT-MESSAGING §3.5.5, which rotates the vault's keys too; reported on a `ROTATE_STATE:`
/// line). Each ends with the vault locked.
extension StagingTests {
    /// Now, in UTC (ISO 8601), for the texts the tests send.
    static func utcNow() -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    /// `VETTID_STAGING_WAIT`: seconds, optional; [fallback] without it.
    static func wait(_ fallback: Int) -> TimeInterval {
        TimeInterval((try? input("VETTID_STAGING_WAIT")).flatMap { Int($0) } ?? fallback)
    }

    /// A remote invitation (24 hours), so that the other member can paste it later.
    static let remoteTtl = "ttl_86400"

    @MainActor
    func testStagingInvite() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password), openConnections(app) else { return }
        tap(anyElement(app, "add_connection"))
        tap(anyElement(app, "add_invite"))
        guard waitForAny(app, ["invite_choose"], timeout: 30) != nil else { return fail(app, "The invitation did not open.") }
        tap(anyElement(app, Self.remoteTtl))
        tapPrimary(app)
        guard waitForAny(app, ["invite_showing"], timeout: Self.network) != nil else {
            return fail(app, "No invitation was made.")
        }
        let link = inviteLink(app)
        print("INVITE_LINK: \(link ?? "none")")
        guard link != nil else { return fail(app, "The invitation's link could not be read.") }
        // The invitation stays open on the vault: the other member's request is approved later (testStagingConnectApprove).
        tap(app.buttons["top_bar_back"].firstMatch)
        lock(app)
    }

    @MainActor
    func testStagingRotate() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        openSettings(app)
        let credentialRow = app.buttons["credential_row"]
        guard reveal(app, credentialRow) else { return fail(app, "Settings has no Credential row.") }
        credentialRow.tap()
        expect(app, "credential", timeout: 30)
        let rotateRow = anyElement(app, "rotate_row")
        guard reveal(app, rotateRow) else { return fail(app, "The Credential screen has no rotation.") }
        rotateRow.tap()
        let field = app.secureTextFields["rotate_password"]
        guard field.waitForExistence(timeout: 30) else { return fail(app, "The rotation did not open.") }
        field.tap()
        field.typeText(password)
        tapPrimary(app)
        let end = waitForAny(app, ["rotate_done", "error"], timeout: Self.network * 2)
        print("ROTATE_STATE: \(end == "rotate_done" ? "done" : end == "error" ? "failed" : "none")")
        guard end == "rotate_done" else { return fail(app, "The rotation did not finish.") }
        failOnSavePassword(app)
        tapPrimary(app)
        lock(app)
    }

    /// The invitation's link as the screen shows it (an `https://` link), nil if it cannot be read.
    @MainActor
    func inviteLink(_ app: XCUIApplication) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        for e in ordered(under: root) {
            for text in [e.label, (e.value as? String) ?? ""] where text.hasPrefix("https://") {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

extension StagingTests {
    /// A look without changing anything: Connections (after `VETTID_STAGING_WAIT` seconds, 10 by default, for what the
    /// vault collects), then Approvals, as screenshots kept in the result bundle. Then the vault is locked.
    @MainActor
    func testStagingLook() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        let wait = UInt32(Self.wait(10))
        if openConnections(app) {
            sleep(wait)
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
    /// safety code of `VETTID_STAGING_SAFETY_CODE` (comma-separated, as the other phone shows them), its row opened and
    /// approved (with the password if asked); each reported on a `CONNECT_STATE:` line. Then the vault is locked.
    @MainActor
    func testStagingApproveRequest() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let codes = try Self.input("VETTID_STAGING_SAFETY_CODE").split(separator: ",").map(String.init)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        for code in codes {
            guard openFromDrawer(app, item: "drawer_approvals", screen: "approvals_screen", what: "Approvals") else { break }
            var rowID: String?
            _ = waitUntil(timeout: Self.network) {
                guard let root = try? app.snapshot() else { return false }
                rowID = ordered(under: root).first { $0.identifier.hasPrefix("approval_") && $0.label.contains("code \(code)") }?.identifier
                return rowID != nil
            }
            guard let rowID else {
                print("CONNECT_STATE: missing")
                continue
            }
            tap(anyElement(app, rowID))
            guard waitForAny(app, ["approval_detail"], timeout: 30) != nil else {
                print("CONNECT_STATE: not_opened")
                continue
            }
            let field = app.secureTextFields["approval_password"]
            if field.waitForExistence(timeout: 3) {
                field.tap()
                field.typeText(password)
            }
            tapPrimary(app)
            let left = waitUntil(timeout: Self.network) { shown(app)["approval_detail"] == nil }
            let failure = shown(app)["failure"]
            print("CONNECT_STATE: \(left && failure == nil ? "approved" : "not_approved")")
            failOnSavePassword(app)
            if !left { tap(app.buttons["top_bar_back"].firstMatch) }
        }
        lock(app)
    }
}

extension StagingTests {
    /// The vault kept open in the conversation with `VETTID_STAGING_PEER_NAME` until a message from it shows
    /// `VETTID_STAGING_EXPECT`, for up to `VETTID_STAGING_WAIT` seconds (600 by default); reported on
    /// a `MESSAGE_RECEIVED:` line, with a screenshot of the conversation. Then the vault is locked.
    @MainActor
    func testStagingWaitMessage() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let expected = try Self.input("VETTID_STAGING_EXPECT")
        let limit = Self.wait(600)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        var received = false
        if openConversation(app, peer: peer) {
            let deadline = Date().addingTimeInterval(limit)
            while !received, Date() < deadline {
                received = waitUntil(timeout: max(min(Self.reopenEvery, deadline.timeIntervalSinceNow), 0)) {
                    incomingContains(app, peer: peer, text: expected)
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
    /// S4: to each connection of `VETTID_STAGING_PEER_NAME` ("Name=label;Name=label", the shown names and the short
    /// labels used in the texts), "`VETTID_STAGING_MESSAGE` to <label> <UTC>" sent and followed to Delivered (a
    /// `MESSAGE_STATE:` line each, in order); then, for up to `VETTID_STAGING_WAIT` seconds (300), each
    /// conversation checked for an incoming message holding `VETTID_STAGING_EXPECT` (a `MESSAGE_RECEIVED:` line each,
    /// in order), with screenshots. Then the vault is locked.
    @MainActor
    func testStagingSendAll() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peers = try Self.input("VETTID_STAGING_PEER_NAME").split(separator: ";").map { pair in
            let p = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (name: p[0], label: p.count > 1 ? p[1] : p[0])
        }
        let prefix = try Self.input("VETTID_STAGING_MESSAGE")
        let expected = try Self.input("VETTID_STAGING_EXPECT")
        let limit = Self.wait(300)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        for peer in peers {
            guard openConversation(app, peer: peer.name) else {
                print("MESSAGE_STATE: none")
                continue
            }
            let text = "\(prefix) to \(peer.label) \(Self.utcNow().suffix(9).dropLast())"
            let composer = anyElement(app, "composer")
            guard composer.waitForExistence(timeout: 30) else {
                print("MESSAGE_STATE: none")
                continue
            }
            composer.tap()
            composer.typeText(text)
            let send = app.buttons["send"]
            _ = waitUntil(timeout: 10) { send.exists && send.isEnabled && send.isHittable }
            send.tap()
            var state: String?
            _ = waitUntil(timeout: Self.delivery) {
                state = outgoingStates(app, text: text).last
                return state == "delivered" || state == "read"
            }
            print("MESSAGE_STATE: \(state ?? "none")")
            tap(app.buttons["top_bar_back"].firstMatch)
        }
        let deadline = Date().addingTimeInterval(limit)
        var got = Array(repeating: false, count: peers.count)
        while got.contains(false), Date() < deadline {
            for (i, peer) in peers.enumerated() where !got[i] {
                if openConversation(app, peer: peer.name) {
                    got[i] = waitUntil(timeout: 5) { incomingContains(app, peer: peer.name, text: expected) }
                    if got[i] || Date() >= deadline { snap(app, "s4-\(peer.label)") }
                    tap(app.buttons["top_bar_back"].firstMatch)
                }
            }
        }
        for g in got { print("MESSAGE_RECEIVED: \(g ? "yes" : "no")") }
        lock(app)
    }
}
