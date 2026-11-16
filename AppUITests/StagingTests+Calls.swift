import XCTest

/// Calls on staging between two phones (VAULT-MESSAGING §10.10): ``testStagingCallPlace`` calls the connection shown as
/// `VETTID_STAGING_PEER_NAME` from its conversation; ``testStagingCallAnswer``, started on the other phone first, waits for
/// that call (up to `VETTID_STAGING_CALL_WAIT` seconds, 180 by default) and answers it. Once the call is active, the caller
/// holds it for `VETTID_STAGING_CALL_SECONDS` (20 by default), checking every second that it stays active, then hangs up; the
/// answering side waits for that end. Each side reports on `CALL_STATE:` lines: `waiting`, `answered`, `microphone`, the
/// statuses the call screen showed on the way (`calling`, `ringing`, `connecting`, `reconnecting`), then `active`,
/// `held <seconds>`, `dropped <seconds>`, `ended`, or `failed` (and `microphone_blocked` when the microphone is turned off for
/// the app). Whatever happens, the call screen is left (hung up or declined, then closed) before the vault is locked. The
/// connection's name is never printed, and no failure message carries it.
extension StagingTests {
    /// From the tap to an active call: the offer rings for 45 s (§10.10), and connecting takes a few seconds more.
    static let callConnect: TimeInterval = 75
    /// After the caller's hang-up, how long the call screen may take to show the end.
    static let callEnd: TimeInterval = 30

    /// The call screen's status texts, as reported.
    static let callStatuses: [String: String] = [
        "Calling…": "calling", "Ringing…": "ringing", "Connecting…": "connecting", "Reconnecting…": "reconnecting",
    ]
    /// The titles of the app's microphone dialogs (`CallStrings`): the explanation, which asks, and the one shown once iOS
    /// has been refused, whose button opens Settings.
    static let microphoneExplainTitle = "Allow the microphone"
    static let microphoneBlockedTitle = "The microphone is turned off for VettID"

    @MainActor
    func testStagingCallPlace() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let hold = try Self.seconds("VETTID_STAGING_CALL_SECONDS", fallback: 20)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        if openConversation(app, peer: peer) {
            let call = anyElement(app, "conversation_call")
            if waitUntil(timeout: 30, { call.exists && call.isEnabled && call.isHittable }) {
                call.tap()
                if callBecomesActive(app), holdCall(app, seconds: hold) {
                    tap(anyElement(app, "call_hang_up"))
                    callEnds(app)
                }
            } else {
                print("CALL_STATE: failed")
                fail(app, "The conversation offers no call button (calls not available for this connection or vault?).")
            }
        }
        leaveCall(app)
        lock(app)
    }

    @MainActor
    func testStagingCallAnswer() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let wait = try Self.seconds("VETTID_STAGING_CALL_WAIT", fallback: 180)
        let hold = try Self.seconds("VETTID_STAGING_CALL_SECONDS", fallback: 20)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password) else { return }
        continueAfterFailure = true
        print("CALL_STATE: waiting")
        let callService = XCUIApplication(bundleIdentifier: "com.apple.InCallService")
        var answered = false
        _ = waitUntil(timeout: wait) {
            let inApp = app.buttons["call_answer"]
            if inApp.exists, inApp.isHittable {
                inApp.tap()
                answered = true
            } else if let accept = callKitAccept(callService) {
                accept.tap()
                answered = true
            }
            return answered
        }
        if answered {
            print("CALL_STATE: answered")
            if callBecomesActive(app) {
                // The caller holds the call, then hangs up: this side waits for that end (an unreadable snapshot is not one).
                _ = waitUntil(timeout: hold + Self.callEnd + 15) { callActive(app) == false }
                callEnds(app)
            }
        } else {
            print("CALL_STATE: failed")
            fail(app, "No incoming call came within VETTID_STAGING_CALL_WAIT.")
        }
        leaveCall(app)
        lock(app)
    }

    /// CallKit's own Accept, when the system shows the incoming call instead of the app's screen (its in-call service).
    @MainActor
    func callKitAccept(_ callService: XCUIApplication) -> XCUIElement? {
        for label in ["Accept", "Answer"] {
            let b = callService.buttons[label]
            if b.exists, b.isHittable { return b }
        }
        return nil
    }

    /// The microphone: the app's own explanation ("Allow"), then the system's permission prompt. False when the app shows the
    /// microphone turned off (iOS asks only once): that is reported and failed, and nothing is tapped (its button opens
    /// Settings).
    @MainActor
    func allowMicrophone(_ app: XCUIApplication) -> Bool {
        // The system's permission prompt is not always an alert element (iOS 27 shows a card): any SpringBoard button of
        // that label, while the prompt names the microphone.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let asking = springboard.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "microphone")).firstMatch
        if asking.exists {
            for label in ["Allow", "OK"] {
                let system = springboard.buttons[label]
                if system.exists, system.isHittable {
                    system.tap()
                    return true
                }
            }
        }
        let alert = app.alerts.firstMatch
        guard alert.exists else { return true }
        if alert.label == Self.microphoneBlockedTitle {
            print("CALL_STATE: microphone_blocked")
            fail(app, "The microphone is turned off for the app (Settings); nothing was tapped.")
            return false
        }
        if alert.label == Self.microphoneExplainTitle {
            let own = alert.buttons["confirm_button"].firstMatch
            if own.exists {
                print("CALL_STATE: microphone")
                own.tap()
            }
        }
        return true
    }

    /// Whether the call is active (its encryption line shows); nil when the app's snapshot could not be read.
    @MainActor
    func callActive(_ app: XCUIApplication) -> Bool? {
        let screen = shown(app)
        return screen.isEmpty ? nil : screen["call_encryption"] != nil
    }

    /// Waits for the call to become active (its encryption line shows), granting the microphone on the way and reporting
    /// each status the screen shows; false, with the reason reported, when it ends or the wait runs out.
    @MainActor
    func callBecomesActive(_ app: XCUIApplication) -> Bool {
        var last: String?
        var ended = false
        var blocked = false
        let active = waitUntil(timeout: Self.callConnect) {
            guard allowMicrophone(app) else {
                blocked = true
                return true
            }
            let screen = shown(app)
            if screen["call_encryption"] != nil { return true }
            if screen["call_ended"] != nil || screen["call_close"] != nil {
                ended = true
                return true
            }
            if let text = screen["call_status"], let state = Self.callStatuses[text], state != last {
                last = state
                print("CALL_STATE: \(state)")
            }
            return false
        }
        if blocked { return false }
        if active, !ended {
            print("CALL_STATE: active")
            snap(app, "call-active")
            return true
        }
        print("CALL_STATE: failed")
        fail(app, ended ? "The call ended before it was active." : "The call did not become active in time.")
        return false
    }

    /// Keeps the active call for [seconds], checking every second that it stays active (two readable snapshots in a row
    /// without it end the hold) and reporting a reconnect; false when it dropped.
    @MainActor
    func holdCall(_ app: XCUIApplication, seconds: TimeInterval) -> Bool {
        let start = Date()
        var missing = 0
        var reconnecting = false
        while Date().timeIntervalSince(start) < seconds {
            let screen = shown(app)
            if !screen.isEmpty {
                missing = screen["call_encryption"] == nil ? missing + 1 : 0
                let now = screen["call_status"] == "Reconnecting…"
                if now, !reconnecting { print("CALL_STATE: reconnecting") }
                reconnecting = now
            }
            if missing >= 2 {
                print("CALL_STATE: dropped \(Int(Date().timeIntervalSince(start)))")
                fail(app, "The call stopped being active while it was held.")
                return false
            }
            Thread.sleep(forTimeInterval: 1)
        }
        print("CALL_STATE: held \(Int(seconds))")
        return true
    }

    /// The end of the call shown, then the screen closed.
    @MainActor
    func callEnds(_ app: XCUIApplication) {
        guard waitForAny(app, ["call_ended", "call_close"], timeout: Self.callEnd) != nil || callActive(app) == false else {
            print("CALL_STATE: failed")
            return fail(app, "The call did not end.")
        }
        print("CALL_STATE: ended")
        snap(app, "call-ended")
        let close = app.buttons["call_close"]
        if close.waitForExistence(timeout: 5) { close.tap() }
    }

    /// Whatever state the call is in, its screen goes (hung up or declined, then closed), so that the shell is reachable and
    /// the vault can be locked: the call screen is a window of its own over the shell.
    @MainActor
    func leaveCall(_ app: XCUIApplication) {
        // A microphone dialog (the calls window shows it with or without a call) is dismissed first, never confirmed: the
        // blocked one's button opens Settings.
        let alert = app.alerts.firstMatch
        if alert.exists, [Self.microphoneBlockedTitle, Self.microphoneExplainTitle].contains(alert.label),
           let dismiss = alert.buttons.allElementsBoundByIndex.first(where: { $0.identifier != "confirm_button" }) {
            dismiss.tap()
        }
        guard anyElement(app, "call_screen").waitForExistence(timeout: 2) else { return }
        for id in ["call_hang_up", "call_decline"] where app.buttons[id].exists {
            app.buttons[id].tap()
            break
        }
        let close = app.buttons["call_close"]
        if close.waitForExistence(timeout: Self.callEnd) { close.tap() }
        _ = waitUntil(timeout: 10) { shown(app)["call_screen"] == nil }
    }
}
