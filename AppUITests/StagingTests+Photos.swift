import XCTest

/// Photos on staging (VAULT-MESSAGING §10.5.1; ANDROID-PLAN "Photo attachments"): ``StagingTests/testStagingPhotoSend``
/// sends the first photo of the system's picker to a connection and follows its bubble to "Delivered",
/// ``StagingTests/testStagingPhotoReceive`` waits for a photo from the connection and opens it in the viewer. The
/// connection is found by its shown name (`VETTID_STAGING_PEER_NAME`). The outcome is reported on `PHOTO_STATE:`,
/// `PHOTO_RECEIVED:` and `PHOTO_VIEWER:` lines; the name is never printed and no failure message carries it.
///
/// A photo bubble is one element named `photo_<message id>`, its label being what VoiceOver says: "Photo you sent.
/// <state>" for an outgoing one (no caption is sent), "Photo from <name>[. <caption>][. <state>]" for an incoming one
/// (the name bidi-isolated), in English, the only localization; its value is "shown" once the thumbnail is drawn.
///
/// The system's Photos picker runs outside the app (IOS-PLAN §4): its grid is reached through the app's element tree,
/// where XCUITest shows the picker's remote view, or else through SpringBoard's.
extension StagingTests {
    /// How long the photo tests wait for the delivery or the arrival, unless `VETTID_STAGING_PHOTO_TIMEOUT` says.
    static let photoWait: TimeInterval = 180
    /// The picker opening and showing its grid.
    static let pickerWait: TimeInterval = 30
    /// An outgoing photo's line as the label ends with it, and as it is reported (anything else is a failure).
    static let photoStates: [String: String] = ["Sending": "sending", "Delivered": "delivered"]
    /// The heads of a photo bubble's label.
    static let photoOut = "Photo you sent"
    static func photoIn(_ peer: String) -> String { "Photo from " + peer }
    /// The viewer's failures in words (`photo_error`'s notice, the type it cannot show), should their identifiers not be
    /// read on the capture-protected layer.
    static let viewerFailures = [
        "This photo could not be opened", "This photo is not in your vault yet", "Your vault is busy right now",
        "This file type isn't supported",
    ]

    // MARK: - The tests' bodies

    @MainActor
    func photoSend() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let timeout = try Self.seconds("VETTID_STAGING_PHOTO_TIMEOUT", fallback: Self.photoWait)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password), openConversation(app, peer: peer) else { return }
        let button = anyElement(app, "photo")
        guard button.waitForExistence(timeout: 30) else {
            return fail(app, "The conversation offers no photo button (is the connection active, and can it take photos?).")
        }
        let before = Set(outgoingPhotos(app).map(\.id))
        guard openPicker(app, button: button), pickFirstPhoto(app), let send = draftSend(app) else { return }
        send.tap()
        guard draftClosed(app, send: send, timeout: timeout) else { return }

        // The new bubble (the lowest one that was not there before), then its line until "Delivered".
        var state: String?
        let done = waitUntil(timeout: timeout) {
            if let mine = outgoingPhotos(app).last(where: { !before.contains($0.id) }) { state = mine.state }
            return state == "delivered" || state == "failed" || shown(app)["conversation_error"] != nil
        }
        print("PHOTO_STATE: \(state ?? "none")")
        if shown(app)["conversation_error"] != nil { return fail(app, "The conversation shows a failure.") }
        guard let state else { return fail(app, "The photo's bubble did not appear.") }
        if state == "failed" { return fail(app, "The photo was not sent: its bubble shows a failure.") }
        guard done else { return fail(app, "The photo was not delivered within \(Int(timeout)) s.") }
        lock(app)
    }

    @MainActor
    func photoReceive() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let peer = try Self.input("VETTID_STAGING_PEER_NAME")
        let timeout = try Self.seconds("VETTID_STAGING_PHOTO_TIMEOUT", fallback: Self.photoWait)

        let app = launch()
        guard openAtStart(app, pin: pin, password: password), openConversation(app, peer: peer) else { return }
        guard let found = waitForIncomingPhoto(app, peer: peer, timeout: timeout) else { return }
        print("PHOTO_RECEIVED: \(found != nil ? "yes" : "no")")
        guard let photo = found else {
            return fail(app, "No photo from the connection showed its thumbnail within \(Int(timeout)) s.")
        }
        guard viewPhoto(app, photo) else { return }
        lock(app)
    }

    // MARK: - Steps

    /// The photo button's menu, then its "Choose photos"; false after the failure.
    @MainActor
    func openPicker(_ app: XCUIApplication, button: XCUIElement) -> Bool {
        guard waitUntil(timeout: 10, { button.isEnabled && button.isHittable }) else {
            fail(app, "The photo button stayed disabled.")
            return false
        }
        button.tap()
        let choose = app.buttons.matching(NSPredicate(format: "identifier == 'photo_choose' OR label == 'Choose photos'")).firstMatch
        guard choose.waitForExistence(timeout: 10) else {
            fail(app, "The photo button's menu has no \"Choose photos\".")
            return false
        }
        choose.tap()
        return true
    }

    /// The lowest photo from [peer] whose thumbnail is drawn, the conversation closed and opened again meanwhile (the
    /// screen has no pull to refresh): `.some(id)`, `.some(nil)` when none came within [timeout], nil after a failure.
    @MainActor
    func waitForIncomingPhoto(_ app: XCUIApplication, peer: String, timeout: TimeInterval) -> String?? {
        var photo: String?
        let deadline = Date().addingTimeInterval(timeout)
        while photo == nil, Date() < deadline {
            let round = min(Self.reopenEvery, deadline.timeIntervalSinceNow)
            _ = waitUntil(timeout: max(round, 0)) {
                photo = incomingPhoto(app, peer: peer)
                return photo != nil
            }
            if photo == nil, Date() < deadline {
                tap(app.buttons["top_bar_back"].firstMatch)
                if waitForAny(app, ["messages_screen", "new_message_screen"], timeout: 30) == nil {
                    fail(app, "The conversation did not close.")
                    return nil
                }
                guard openConversation(app, peer: peer) else { return nil }
            }
        }
        return .some(photo)
    }

    /// The bubble [photo] opened in the viewer, the photo shown there (reported on a `PHOTO_VIEWER:` line), and the
    /// viewer closed on the conversation; false after the failure.
    @MainActor
    func viewPhoto(_ app: XCUIApplication, _ photo: String) -> Bool {
        let bubble = anyElement(app, photo)
        for _ in 0..<4 where !bubble.isHittable {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        guard bubble.isHittable else {
            fail(app, "The photo's bubble cannot be tapped.")
            return false
        }
        bubble.tap()
        if waitForAny(app, ["photo_viewer", "photo_image", "photo_error", "photo_undecodable"], timeout: 30) == nil {
            fail(app, "The photo viewer did not open.")
            return false
        }
        var outcome = "loading"
        _ = waitUntil(timeout: Self.network) {
            outcome = viewerOutcome(app)
            return outcome != "loading"
        }
        print("PHOTO_VIEWER: \(outcome)")
        guard outcome == "shown" else {
            fail(app, outcome == "failed" ? "The viewer shows a failure, not the photo." : "The viewer did not show the photo.")
            return false
        }
        tap(app.buttons["top_bar_back"].firstMatch)
        if waitForAny(app, ["conversation_screen"], timeout: 30) == nil {
            fail(app, "The viewer did not close.")
            return false
        }
        return true
    }

    /// In the system's Photos picker: the first photo it shows, then its "Add" when it asks for one (several photos may be
    /// picked), until the prepared photo shows; false after the failure. An empty library fails with that said.
    @MainActor
    func pickFirstPhoto(_ app: XCUIApplication) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var picked: XCUIElement?
        var empty = false
        _ = waitUntil(timeout: Self.pickerWait) {
            picked = pickerPhoto(in: app) ?? pickerPhoto(in: springboard)
            empty = libraryEmpty(in: app) || libraryEmpty(in: springboard)
            return picked != nil || empty
        }
        if empty, picked == nil {
            fail(app, "The phone's photo library is empty: add at least one photo to it by hand (the test never adds one).")
            return false
        }
        guard let picked else {
            fail(app, "The Photos picker showed no photo the test could reach.")
            return false
        }
        picked.tap()

        // The picker closes by itself, or once its "Add" is tapped; then the photo is prepared.
        let draft = waitUntil(timeout: Self.pickerWait) {
            if draftShown(app) { return true }
            if let add = pickerConfirm(in: app) ?? pickerConfirm(in: springboard) { add.tap() }
            return false
        }
        if !draft {
            fail(app, "The picked photo did not reach the draft.")
            return false
        }
        return true
    }

    /// The draft's Send, once the photo is prepared and it can be tapped; nil after the failure.
    @MainActor
    func draftSend(_ app: XCUIApplication) -> XCUIElement? {
        let byId = anyElement(app, "photo_send")
        let byLabel = app.buttons.matching(NSPredicate(format: "label == 'Send' AND identifier != 'send'")).firstMatch
        var send: XCUIElement?
        _ = waitUntil(timeout: Self.network) {
            if draftProblem(app) != nil { return true }
            send = [byId, byLabel].first { $0.exists && $0.isEnabled && $0.isHittable }
            return send != nil
        }
        if let problem = draftProblem(app) {
            fail(app, "The photo could not be prepared: \(problem.isEmpty ? "the draft shows a problem" : problem)")
            return nil
        }
        guard let send else {
            fail(app, "The draft's Send stayed disabled; nothing was sent.")
            return nil
        }
        return send
    }

    /// The draft closed after Send (every photo sent); false after the failure (a problem, or still open).
    @MainActor
    func draftClosed(_ app: XCUIApplication, send: XCUIElement, timeout: TimeInterval) -> Bool {
        _ = waitUntil(timeout: timeout) { draftProblem(app) != nil || (!send.exists && !draftShown(app)) }
        if let problem = draftProblem(app) {
            fail(app, "The photo was not sent: \(problem.isEmpty ? "the draft shows a problem" : problem)")
            return false
        }
        if send.exists || draftShown(app) {
            fail(app, "The draft did not close within \(Int(timeout)) s of Send.")
            return false
        }
        return true
    }

    // MARK: - Reading the screen

    /// A photo of the picker's grid that can be tapped: an image whose label reads like the picker's ("Photo, <date>",
    /// "Live Photo, …", "Screenshot, …"), or else the first image of its scrolling grid.
    @MainActor
    func pickerPhoto(in root: XCUIApplication) -> XCUIElement? {
        let labelled = root.images.matching(NSPredicate(format: "label CONTAINS ', '")).firstMatch
        let grid = root.scrollViews.otherElements.images.firstMatch
        return [labelled, grid].first { $0.exists && $0.isHittable }
    }

    /// The picker says the library has nothing to pick.
    @MainActor
    func libraryEmpty(in root: XCUIApplication) -> Bool {
        root.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] 'No Photos'")).firstMatch.exists
    }

    /// The picker's button that hands the selection over, when it shows one.
    @MainActor
    func pickerConfirm(in root: XCUIApplication) -> XCUIElement? {
        let add = root.buttons.matching(NSPredicate(format: "label IN {'Add', 'Done'}")).firstMatch
        return add.exists && add.isEnabled && add.isHittable ? add : nil
    }

    /// The prepared photos are on screen (by the draft's identifiers, or its Send by label).
    @MainActor
    func draftShown(_ app: XCUIApplication) -> Bool {
        let screen = shown(app)
        if ["photo_draft", "photo_send", "photo_cancel", "photo_caption"].contains(where: { screen[$0] != nil }) { return true }
        return app.buttons.matching(NSPredicate(format: "label == 'Send' AND identifier != 'send'")).firstMatch.exists
    }

    /// The draft's problem notice: its text, or "" when it has none to read; nil without one.
    @MainActor
    func draftProblem(_ app: XCUIApplication) -> String? {
        let screen = shown(app)
        guard let problem = screen["photo_problem"] ?? screen["photo_failed_picks"] else { return nil }
        return problem
    }

    /// The outgoing photo bubbles, top to bottom, with their line (`sending`, `delivered`, `failed`, or `none` while it
    /// has none).
    @MainActor
    func outgoingPhotos(_ app: XCUIApplication) -> [(id: String, state: String)] {
        guard let root = try? app.snapshot() else { return [] }
        return ordered(under: root).compactMap { e in
            guard e.identifier.hasPrefix("photo_") else { return nil }
            let label = Self.plain(e.label)
            if label == Self.photoOut { return (e.identifier, "none") }
            guard label.hasPrefix(Self.photoOut + ". "), let dot = label.range(of: ". ", options: .backwards) else { return nil }
            return (e.identifier, Self.photoStates[String(label[dot.upperBound...])] ?? "failed")
        }
    }

    /// The identifier of the lowest photo bubble from [peer] whose thumbnail is drawn; nil if none.
    @MainActor
    func incomingPhoto(_ app: XCUIApplication, peer: String) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        let head = Self.photoIn(peer)
        return ordered(under: root).last { e in
            guard e.identifier.hasPrefix("photo_"), (e.value as? String) == "shown" else { return false }
            let label = Self.plain(e.label)
            return label == head || label.hasPrefix(head + ". ")
        }?.identifier
    }

    /// What the viewer shows: `shown` (the photo), `failed` (its failure notice, or a type it cannot show) or `loading`.
    @MainActor
    func viewerOutcome(_ app: XCUIApplication) -> String {
        guard let root = try? app.snapshot() else { return "loading" }
        var outcome = "loading"
        for e in ordered(under: root) {
            if ["photo_error", "photo_retry", "photo_undecodable"].contains(e.identifier)
                || Self.viewerFailures.contains(where: { e.label.contains($0) }) {
                return "failed"
            }
            if e.identifier == "photo_image" || (e.elementType == .image && e.label == "Photo") { outcome = "shown" }
        }
        return outcome
    }
}
