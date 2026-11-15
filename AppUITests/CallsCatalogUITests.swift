import XCTest

// swiftlint:disable line_length

/// The call screens of the debug catalog (`-vettid.start calls`): each row opens its screen, and the screen shows its texts, the
/// right buttons and nothing else of the call's controls. Run with the `VettIDScreenshots` scheme (simulator); the screens are
/// kept as attachments.
final class CallsCatalogUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The catalog row's id, the texts the screen shows, and the controls (by accessibility id) that must exist.
    struct Case {
        let row: String
        let texts: [String]
        let controls: [String]
        let absent: [String]

        init(_ row: String, texts: [String], controls: [String] = [], absent: [String] = []) {
            self.row = row
            self.texts = texts
            self.controls = controls
            self.absent = absent
        }
    }

    static let cases = [
        Case("incoming", texts: ["Ada Lovelace", "Answer", "Decline"], controls: ["call_answer", "call_decline"],
             absent: ["call_hang_up", "call_mute", "call_speaker"]),
        Case("calling", texts: ["Calling…", "Mute", "Hang up", "Speaker"], controls: ["call_mute", "call_hang_up", "call_speaker"],
             absent: ["call_answer", "call_decline"]),
        Case("ringing", texts: ["Ringing…", "Hang up"], controls: ["call_hang_up"]),
        Case("connecting", texts: ["Connecting…", "Hang up"], controls: ["call_hang_up"]),
        Case("active", texts: ["4:12", "End-to-end encrypted. Only you and", "Hang up"],
             controls: ["call_encryption", "call_hang_up", "call_mute", "call_speaker"]),
        Case("active_hour", texts: ["1:04:12"], controls: ["call_encryption"]),
        Case("reconnecting", texts: ["Reconnecting…", "Hang up"]),
        Case("ended_ownerCheckRequired", texts: ["Confirm it's you before calling. Your daily check is due.", "Close"], controls: ["call_close"]),
        Case("ended_notSupported", texts: ["Calls are not available for your vault yet", "Close"], controls: ["call_close"]),
        Case("ended_noAddress", texts: ["VettID cannot reach the network for calls. Check that this phone is online and that VettID is allowed to use the network."]),
        Case("ended_couldNotConnect", texts: ["Couldn't connect the call. Try calling again."]),
        Case("ended_notEncrypted", texts: ["This call couldn't be encrypted, so it was ended. Try calling again."], controls: ["call_ended"]),
        Case("ended_failed", texts: ["The call failed. Try again."]),
        Case("ended_ownVaultBusy", texts: ["You are already on a call"]),
        Case("ended_callsOff", texts: ["Calls with", "are off."]),
        Case("microphone_explain", texts: ["Allow the microphone", "Allow", "Not now"]),
        Case("microphone_blocked", texts: ["The microphone is turned off for VettID", "Open Settings", "Close"]),
        // A conversation with call lines: every outcome and duration format, the note, and the Call action (hidden during a call).
        Case("conversation_calls", texts: ["Call, 4 min 12 s", "Call, 1 h 4 min", "Call, 12 s", "Call declined", "Call you declined",
                                           "Call not answered: busy", "Call not answered ·", "Missed call", "Call failed",
                                           "Some calls couldn't be shown."],
             controls: ["conversation_call", "calls_not_shown", "conversation_call_entry"]),
        Case("conversation_in_call", texts: ["Missed call", "Call, 4 min 12 s"], controls: ["conversation_call_entry"],
             absent: ["conversation_call", "calls_not_shown"]),
    ]

    @MainActor
    func testEveryCallScreenOfTheCatalog() {
        let app = XCUIApplication()
        app.launchArguments = ["-vettid.start", "calls", "-vettid.theme", "dark"]
        app.launch()
        for c in Self.cases {
            let row = app.buttons["catalog_calls_\(c.row)"].firstMatch
            for _ in 0..<30 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(row.exists, "\(c.row) not in the catalog")
            sleep(1)
            row.tap()
            for text in c.texts {
                // Texts are found by label, in any element (a name is isolated, so it is matched as contained).
                let found = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
                XCTAssertTrue(found.waitForExistence(timeout: 5), "\(c.row): \(text) not shown")
            }
            for id in c.controls {
                XCTAssertTrue(app.descendants(matching: .any)[id].firstMatch.exists, "\(c.row): \(id) missing")
            }
            for id in c.absent {
                XCTAssertFalse(app.descendants(matching: .any)[id].firstMatch.exists, "\(c.row): \(id) shown")
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "calls-\(c.row)"
            shot.lifetime = .keepAlways
            add(shot)
            // A dialog first (its button), then the screen's catalog close.
            if c.row.hasPrefix("microphone") {
                let button = app.alerts.buttons.element(boundBy: 1)
                if button.waitForExistence(timeout: 3) { button.tap() }
            }
            let back = app.buttons["catalog_calls_back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "\(c.row): no way back")
            back.tap()
            for _ in 0..<10 where back.exists { usleep(200_000) }
        }
    }
}
// swiftlint:enable line_length
