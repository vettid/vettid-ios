import XCTest

/// Messages on staging (VAULT-MESSAGING §10.5): ``StagingTests/testStagingMessageSend`` sends a message to a connection
/// and follows its bubble to "Delivered", ``StagingTests/testStagingMessageReceive`` waits for the connection's message.
/// The connection is found by its shown name (`VETTID_STAGING_PEER_NAME`). The outcome is reported on a
/// `MESSAGE_STATE:` or `MESSAGE_RECEIVED:` line; the message text, the expected text and the name are never printed and
/// no failure message carries them.
///
/// The bubbles carry no identifier (each reads as one element, its label being what VoiceOver says): an outgoing bubble
/// reads "You: <text>. <time>, <state>", an incoming one "<name>: <text>. <time>" (the name bidi-isolated), in English,
/// the only localization.
extension StagingTests {
    /// The other member's vault acknowledging a message, through the relay (VAULT-MESSAGING §10.5.1).
    static let delivery: TimeInterval = 180
    /// How long the receiving side waits for the other member's message.
    static let arrival: TimeInterval = 60
    /// While waiting for a message: how often the conversation is closed and opened again.
    static let reopenEvery: TimeInterval = 20
    /// An outgoing bubble's states as the label ends with them, and as they are reported.
    static let messageStates: [String: String] = ["Sent": "sent", "Delivered": "delivered", "Read": "read"]
    /// The identifiers of the conversation screen that start like a row's own `conversation_<id>`.
    static let conversationParts: Set<String> = [
        "conversation_screen", "conversation_error", "conversation_details", "conversation_loading", "conversation_empty",
        "conversation_inactive",
    ]

    // MARK: - The tests' bodies

    @MainActor
    func messageSend() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let text = try Self.input("VETTID_STAGING_MESSAGE")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password), openConversation(app, peer: peer) else { return }
        let composer = anyElement(app, "composer")
        guard composer.waitForExistence(timeout: 30) else {
            return fail(app, "The conversation offers no reply field (is the connection active?).")
        }
        let before = outgoingStates(app, text: text).count
        composer.tap()
        composer.typeText(text)
        // Autocorrection must not have changed what is sent.
        guard waitUntil(timeout: 5, { (composer.value as? String) == text }) else {
            return fail(app, "The reply field does not hold the message as given (autocorrected?); nothing was sent.")
        }
        let send = app.buttons["send"]
        guard waitUntil(timeout: 10, { send.exists && send.isEnabled && send.isHittable }) else {
            return fail(app, "\"Send\" stayed disabled; nothing was sent.")
        }
        send.tap()

        // The new bubble, then its state until "Delivered" (or "Read").
        var state: String?
        let done = waitUntil(timeout: Self.delivery) {
            let states = outgoingStates(app, text: text)
            if states.count > before { state = states.last }
            return state == "delivered" || state == "read" || shown(app)["conversation_error"] != nil
        }
        print("MESSAGE_STATE: \(state ?? "none")")
        if shown(app)["conversation_error"] != nil { return fail(app, "The conversation shows a failure.") }
        guard state != nil else { return fail(app, "The message's bubble did not appear.") }
        guard done else { return fail(app, "The message was not delivered within \(Int(Self.delivery)) s.") }
        lock(app)
    }

    @MainActor
    func messageReceive() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let expected = try Self.input("VETTID_STAGING_EXPECT")

        let app = launch()
        guard openAtStart(app, pin: pin, password: password), openConversation(app, peer: peer) else { return }
        var received = false
        let deadline = Date().addingTimeInterval(Self.arrival)
        while !received, Date() < deadline {
            let round = min(Self.reopenEvery, deadline.timeIntervalSinceNow)
            received = waitUntil(timeout: max(round, 0)) { incomingContains(app, peer: peer, text: expected) }
            // The screen has no pull to refresh: the conversation is closed and opened again.
            if !received, Date() < deadline {
                tap(app.buttons["top_bar_back"].firstMatch)
                if waitForAny(app, ["messages_screen", "new_message_screen"], timeout: 30) == nil {
                    return fail(app, "The conversation did not close.")
                }
                guard openConversation(app, peer: peer) else { return }
            }
        }
        print("MESSAGE_RECEIVED: \(received ? "yes" : "no")")
        guard received else { return fail(app, "No message from the connection with the expected text within \(Int(Self.arrival)) s.") }
        lock(app)
    }

    // MARK: - Steps

    /// The conversation with the connection shown as [peer]: from its row on Messages, or else from the compose button's
    /// picker (no conversation yet); false after the failure.
    @MainActor
    func openConversation(_ app: XCUIApplication, peer: String) -> Bool {
        if shown(app)["messages_screen"] == nil, shown(app)["new_message_screen"] == nil {
            guard openFromDrawer(app, item: "drawer_messages", screen: "messages_screen", what: "Messages") else { return false }
        }
        if shown(app)["messages_screen"] != nil {
            _ = waitForAny(app, ["conversations", "messages_empty", "messages_error", "messages_no_match"], timeout: Self.network)
            if let row = row(app, prefix: "conversation_", named: peer, excluding: Self.conversationParts) {
                tap(anyElement(app, row))
                return conversationOpened(app)
            }
            tap(app.buttons["messages_compose"])
            if waitForAny(app, ["new_message_screen"], timeout: 30) == nil {
                fail(app, "The new-message picker did not open.")
                return false
            }
        }
        var pick: String?
        _ = waitUntil(timeout: Self.network) {
            pick = row(app, prefix: "pick_", named: peer, excluding: [])
            return pick != nil || shown(app)["new_message_invite"] != nil
        }
        guard let pick else {
            fail(app, "No conversation and no active connection shown as VETTID_STAGING_PEER_NAME.")
            return false
        }
        tap(anyElement(app, pick))
        return conversationOpened(app)
    }

    /// The conversation screen, opened and loaded; false after the failure.
    @MainActor
    func conversationOpened(_ app: XCUIApplication) -> Bool {
        if waitForAny(app, ["conversation_screen"], timeout: 30) == nil {
            fail(app, "The conversation did not open.")
            return false
        }
        if !waitUntil(timeout: Self.network, { let s = shown(app); return !s.isEmpty && s["conversation_loading"] == nil }) {
            fail(app, "The conversation did not finish loading.")
            return false
        }
        return true
    }

    /// A top-level screen from the drawer (back arrows first, up to the screen with the menu button); false after the
    /// failure.
    @MainActor
    func openFromDrawer(_ app: XCUIApplication, item: String, screen: String, what: String) -> Bool {
        let menu = app.buttons["top_bar_menu"]
        for _ in 0..<4 where !menu.waitForExistence(timeout: 3) {
            let back = app.buttons["top_bar_back"].firstMatch
            guard back.exists, back.isHittable else { break }
            back.tap()
        }
        tap(menu)
        tap(app.buttons[item])
        if waitForAny(app, [screen], timeout: 30) != screen {
            fail(app, "\(what) did not open.")
            return false
        }
        return true
    }

    // MARK: - Reading the screen

    /// The identifier of the first row (`<prefix><id>`) whose text includes the name [name] as one of its parts (the
    /// row reads as one element: "<name>, <date>, <latest message>"), scrolling the list down a few times; nil if none.
    @MainActor
    func row(_ app: XCUIApplication, prefix: String, named name: String, excluding: Set<String>) -> String? {
        for attempt in 0..<5 {
            if attempt > 0 { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
            guard let root = try? app.snapshot() else { continue }
            for e in ordered(under: root) where e.identifier.hasPrefix(prefix) && !excluding.contains(e.identifier) {
                let label = Self.plain(e.label)
                if label == name || label.hasPrefix(name + ",") || label.components(separatedBy: ", ").contains(name) {
                    return e.identifier
                }
            }
        }
        return nil
    }

    /// The states of the outgoing bubbles of [text], top to bottom (`sent`, `delivered`, `read`).
    @MainActor
    func outgoingStates(_ app: XCUIApplication, text: String) -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        let start = "You: " + text + ". "
        return ordered(under: root).compactMap { e in
            let label = Self.plain(e.label)
            guard label.hasPrefix(start), let comma = label.range(of: ", ", options: .backwards) else { return nil }
            return Self.messageStates[String(label[comma.upperBound...])]
        }
    }

    /// Whether an incoming bubble from [peer] shows [text].
    @MainActor
    func incomingContains(_ app: XCUIApplication, peer: String, text: String) -> Bool {
        guard let root = try? app.snapshot() else { return false }
        return ordered(under: root).contains { e in
            let label = Self.plain(e.label)
            return label.hasPrefix(peer + ": ") && label.contains(text)
        }
    }

    /// The elements under [root] in the order they are drawn (depth first, top to bottom).
    @MainActor
    func ordered(under root: any XCUIElementSnapshot) -> [any XCUIElementSnapshot] {
        var out: [any XCUIElementSnapshot] = []
        var stack: [any XCUIElementSnapshot] = [root]
        while let e = stack.popLast() {
            out.append(e)
            stack.append(contentsOf: e.children.reversed())
        }
        return out
    }

    /// [label] without the bidi isolation marks around a name (VAULT-MESSAGING §10.8).
    static func plain(_ label: String) -> String {
        String(String.UnicodeScalarView(label.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) }))
    }
}
