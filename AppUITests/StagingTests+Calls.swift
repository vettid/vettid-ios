import XCTest

/// Calls on staging between two phones (VAULT-MESSAGING §10.10): ``testStagingCallPlace`` calls the connection shown as
/// `VETTID_STAGING_PEER_NAME` from its conversation; ``testStagingCallAnswer``, started on the other phone first, waits for
/// that call (up to `VETTID_STAGING_CALL_WAIT` seconds, 180 by default) and answers it. Once the call is active, the caller
/// holds it for `VETTID_STAGING_CALL_SECONDS` (20 by default), checking every second that it stays active, then hangs up; the
/// answering side waits for that end. Each side reports on `CALL_STATE:` lines: the statuses the call screen showed on the
/// way (`calling`, `ringing`, `connecting`, `reconnecting`), then `active`, `held <seconds>`, `ended`, or `failed`. The
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
                if callBecomesActive(app) {
                    holdCall(app, seconds: hold)
                    tap(anyElement(app, "call_hang_up"))
                    callEnds(app)
                }
            } else {
                print("CALL_STATE: failed")
                fail(app, "The conversation offers no call button (calls not available for this connection or vault?).")
            }
        }
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
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var answered = false
        _ = waitUntil(timeout: wait) {
            let inApp = app.buttons["call_answer"]
            if inApp.exists, inApp.isHittable {
                inApp.tap()
                answered = true
            } else if let accept = callKitAccept(springboard) {
                accept.tap()
                answered = true
            }
            return answered
        }
        if answered {
            print("CALL_STATE: answered")
            if callBecomesActive(app) {
                // The caller holds the call, then hangs up: this side waits for that end.
                _ = waitUntil(timeout: hold + Self.callEnd + 15) { !callIsActive(app) }
                callEnds(app)
            }
        } else {
            print("CALL_STATE: failed")
            fail(app, "No incoming call came within VETTID_STAGING_CALL_WAIT.")
        }
        lock(app)
    }

    /// CallKit's own Accept button, when the system shows the incoming call instead of the app's screen.
    @MainActor
    func callKitAccept(_ springboard: XCUIApplication) -> XCUIElement? {
        for label in ["Accept", "Answer"] {
            let b = springboard.buttons[label]
            if b.exists, b.isHittable { return b }
        }
        return nil
    }

    /// The microphone: the app's own explanation ("Allow"), then the system's permission alert.
    @MainActor
    func allowMicrophone(_ app: XCUIApplication) {
        // The system's permission prompt is not always an alert element (iOS 27 shows a card): any SpringBoard button of
        // that label, while the prompt names the microphone.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let asking = springboard.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "microphone")).firstMatch
        if asking.exists {
            for label in ["Allow", "OK"] {
                let system = springboard.buttons[label]
                if system.exists, system.isHittable {
                    system.tap()
                    return
                }
            }
        }
        // The app's own explanation is an alert ("Allow the microphone"), its Allow button `confirm_button`.
        let alert = app.alerts.firstMatch
        if alert.exists, alert.label.localizedCaseInsensitiveContains("microphone") {
            let own = alert.buttons["confirm_button"].firstMatch
            if own.exists {
                print("CALL_STATE: microphone")
                own.tap()
            }
        }
    }

    @MainActor
    func callIsActive(_ app: XCUIApplication) -> Bool { shown(app)["call_encryption"] != nil }

    /// Waits for the call to become active (its encryption line shows), granting the microphone on the way and reporting
    /// each status the screen shows; false, with the reason reported, when it ends or the wait runs out.
    @MainActor
    func callBecomesActive(_ app: XCUIApplication) -> Bool {
        var last: String?
        var ended = false
        let active = waitUntil(timeout: Self.callConnect) {
            allowMicrophone(app)
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
        if active, !ended {
            print("CALL_STATE: active")
            snap(app, "call-active")
            return true
        }
        print("CALL_STATE: failed")
        fail(app, ended ? "The call ended before it was active." : "The call did not become active in time.")
        return false
    }

    /// Keeps the active call for [seconds], checking every second that it stays active.
    @MainActor
    func holdCall(_ app: XCUIApplication, seconds: TimeInterval) {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            guard callIsActive(app) else {
                print("CALL_STATE: dropped \(Int(Date().timeIntervalSince(start)))")
                fail(app, "The call stopped being active while it was held.")
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        print("CALL_STATE: held \(Int(seconds))")
    }

    /// The end of the call shown, then the screen closed.
    @MainActor
    func callEnds(_ app: XCUIApplication) {
        guard waitForAny(app, ["call_ended", "call_close"], timeout: Self.callEnd) != nil || !callIsActive(app) else {
            print("CALL_STATE: failed")
            return fail(app, "The call did not end.")
        }
        print("CALL_STATE: ended")
        snap(app, "call-ended")
        let close = app.buttons["call_close"]
        if close.waitForExistence(timeout: 5) { close.tap() }
    }
}
