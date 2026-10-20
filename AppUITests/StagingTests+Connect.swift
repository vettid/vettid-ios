import XCTest

/// The connect flow on staging (VAULT-MESSAGING §6.4): ``StagingTests/testStagingConnectAccept`` on the phone that
/// accepts another member's invitation link, ``StagingTests/testStagingConnectApprove`` on the inviter's phone. The
/// safety code is reported (an attachment named `safety-code` and a `SAFETY_CODE: <code>` line) so that the two sides
/// can be compared; it is not one of the secret inputs. The link is never printed and no failure message carries it.
extension StagingTests {
    /// The handshake with the other member's vault through the relay, until a safety code shows.
    static let handshake: TimeInterval = 300
    /// Identifiers inside a request card (or beside it) that start like a card's own `request_<id>`.
    static let requestParts: Set<String> = ["request_name", "request_approve", "request_decline", "request_ended", "request_ended_ok"]

    /// A request card as one snapshot shows it.
    struct ShownRequest {
        let id: String
        let sas: String?
        let canApprove: Bool
        let approved: Bool
    }

    // MARK: - The tests' bodies

    @MainActor
    func connectAccept() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let link = try Self.input("VETTID_STAGING_LINK")
        guard link.hasPrefix("https://") else { throw ConnectInputError.linkNotHttps }

        let app = launch()
        guard openAtStart(app, pin: pin, password: password), openConnections(app) else { return }
        tap(anyElement(app, "add_connection"))
        tap(anyElement(app, "add_paste"))
        expect(app, "accept_input", timeout: 30)
        guard enterLink(app, link) else { return }
        tapPrimary(app)

        // The handshake (§6.4): "Waiting for <name>'s vault", then the compare screen with the safety code.
        let outcomes = ["accept_compare", "accept_approved", "accept_exists", "accept_ended", "accept_peer_declined", "connected"]
        let outcome = waitForAny(app, outcomes, timeout: Self.handshake)
        guard outcome == "accept_compare" || outcome == "accept_approved" else {
            let waiting = shown(app)["accept_waiting"] != nil ? " Still waiting for the other member's vault." : ""
            return fail(app, "No safety code to compare: \(outcome ?? "no answer").\(waiting)")
        }
        var found: String?
        _ = waitUntil(timeout: 30) {
            found = safetyCode(in: app)
            return found != nil
        }
        guard let code = found else { return fail(app, "The compare screen shows no safety code.") }
        report(safetyCode: code)
        lock(app)
    }

    @MainActor
    func connectApprove() throws {
        let pin = try Self.pin()
        let password = try Self.input("VETTID_STAGING_PASSWORD")
        let expected = try Self.optionalSafetyCode()

        let app = launch()
        guard openAtStart(app, pin: pin, password: password), openConnections(app) else { return }
        guard let card = requestToApprove(app, expected: expected) else { return }
        guard let sas = card.sas else { return fail(app, "The request shows no safety code; nothing was approved.") }
        report(safetyCode: sas)

        let approve = anyElement(app, card.id).descendants(matching: .any).matching(identifier: "request_approve").firstMatch
        guard reveal(app, approve) else { return fail(app, "The request's \"Approve\" cannot be reached; nothing was approved.") }
        approve.tap()

        var state: String?
        _ = waitUntil(timeout: Self.network) {
            state = connectState(app, cardId: card.id)
            return state != nil
        }
        print("CONNECT_STATE: \(state ?? "unknown")")
        guard state == "approved_waiting_for_peer" || state == "connected" else {
            return fail(app, "The approval did not go through: \(state ?? "no answer within \(Int(Self.network)) s").")
        }
        lock(app)
    }

    // MARK: - Steps

    /// Connections, from the drawer (back arrows first, up to the screen with the menu button); false after the failure.
    @MainActor
    func openConnections(_ app: XCUIApplication) -> Bool {
        let menu = app.buttons["top_bar_menu"]
        for _ in 0..<4 where !menu.waitForExistence(timeout: 3) {
            let back = app.buttons["top_bar_back"].firstMatch
            guard back.exists, back.isHittable else { break }
            back.tap()
        }
        tap(menu)
        tap(app.buttons["drawer_connections"])
        if waitForAny(app, ["connections_screen"], timeout: 30) != "connections_screen" {
            fail(app, "Connections did not open.")
            return false
        }
        return true
    }

    /// The link typed into the accept screen's field, the keyboard then put away; false after the failure.
    @MainActor
    func enterLink(_ app: XCUIApplication, _ link: String) -> Bool {
        let named = app.textFields["invite_input"]
        let field = named.waitForExistence(timeout: 5) ? named : app.textFields.firstMatch
        guard field.waitForExistence(timeout: 10) else {
            fail(app, "The accept screen has no field for the link.")
            return false
        }
        field.tap()
        field.typeText(link)
        dismissKeyboard(app)
        return true
    }

    /// The request card to approve, once it has arrived: the one showing [expected] when given, otherwise the only one;
    /// nil after the failure (nothing approved).
    @MainActor
    func requestToApprove(_ app: XCUIApplication, expected: String?) -> ShownRequest? {
        var cards: [ShownRequest] = []
        _ = waitUntil(timeout: Self.handshake) {
            cards = requestCards(app).filter(\.canApprove)
            return !cards.isEmpty || shown(app)["connections_error"] != nil
        }
        if cards.isEmpty {
            let error = shown(app)["connections_error"].map { " Connections shows an error: \($0)" } ?? ""
            fail(app, "No connection request to approve appeared within \(Int(Self.handshake)) s.\(error)")
            return nil
        }
        guard let expected else {
            if cards.count == 1 { return cards[0] }
            fail(app, "\(cards.count) requests can be approved: set VETTID_STAGING_SAFETY_CODE to choose one.")
            return nil
        }
        if let match = cards.first(where: { $0.sas == expected }) { return match }
        let seen = cards.map { $0.sas ?? "none" }.joined(separator: ", ")
        fail(app, "No request shows the safety code \(expected) (shown: \(seen)); nothing was approved.")
        return nil
    }

    /// What the list shows after the approval of the card [cardId]: `approved_waiting_for_peer` (the card waits for the
    /// other member), `connected` (the card left the list), `ended`, `peer_declined` or `error`; nil while undecided or
    /// when the snapshot fails.
    @MainActor
    func connectState(_ app: XCUIApplication, cardId: String) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        let ids = identifiers(under: root)
        guard ids.contains("connections_screen") else { return nil }
        if ids.contains("connections_error") { return "error" }
        if ids.contains("request_ended") { return "ended" }
        if ids.contains(where: { $0.hasPrefix("peer_declined_") && $0 != "peer_declined_ok" }) { return "peer_declined" }
        if let card = requestCards(under: root).first(where: { $0.id == cardId }) {
            return card.approved ? "approved_waiting_for_peer" : nil
        }
        return "connected"
    }

    /// Reports the safety code: an attachment kept with the result, and one `SAFETY_CODE:` line in the output.
    @MainActor
    func report(safetyCode code: String) {
        let note = XCTAttachment(string: code)
        note.name = "safety-code"
        note.lifetime = .keepAlways
        add(note)
        print("SAFETY_CODE: \(code)")
    }

    // MARK: - Reading the screen

    /// The first element with [id], whatever its type.
    @MainActor
    func anyElement(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The safety code on screen, from one snapshot.
    @MainActor
    func safetyCode(in app: XCUIApplication) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        return safetyCode(under: root)
    }

    /// The 6-digit safety code under [root]: the label of the box named `sas`, or of the code itself ("Safety code 1 2 3
    /// 4 5 6", which is how it reads out when the box is on the capture-protected layer).
    @MainActor
    func safetyCode(under root: any XCUIElementSnapshot) -> String? {
        var stack: [any XCUIElementSnapshot] = [root]
        while let e = stack.popLast() {
            if e.identifier == "sas" || e.label.hasPrefix("Safety code") {
                let digits = e.label.filter { $0.isASCII && $0.isNumber }
                if digits.count == 6 { return digits }
            }
            stack.append(contentsOf: e.children)
        }
        return nil
    }

    /// Every identifier under [root].
    @MainActor
    func identifiers(under root: any XCUIElementSnapshot) -> Set<String> {
        var found: Set<String> = []
        var stack: [any XCUIElementSnapshot] = [root]
        while let e = stack.popLast() {
            if !e.identifier.isEmpty { found.insert(e.identifier) }
            stack.append(contentsOf: e.children)
        }
        return found
    }

    /// The request cards on screen, from one snapshot.
    @MainActor
    func requestCards(_ app: XCUIApplication) -> [ShownRequest] {
        guard let root = try? app.snapshot() else { return [] }
        return requestCards(under: root)
    }

    /// The request cards (`request_<id>`) under [root], with their safety code and whether they can be approved or wait
    /// for the other member.
    @MainActor
    func requestCards(under root: any XCUIElementSnapshot) -> [ShownRequest] {
        var cards: [ShownRequest] = []
        var stack: [any XCUIElementSnapshot] = [root]
        while let e = stack.popLast() {
            let id = e.identifier
            if id.hasPrefix("request_"), !Self.requestParts.contains(id) {
                let ids = identifiers(under: e)
                cards.append(ShownRequest(
                    id: id, sas: safetyCode(under: e), canApprove: ids.contains("request_approve"), approved: ids.contains("waiting_peer")
                ))
                continue
            }
            stack.append(contentsOf: e.children)
        }
        return cards
    }

    // MARK: - Inputs

    /// `VETTID_STAGING_SAFETY_CODE`, its six digits (spaces and dashes allowed); nil when not set.
    static func optionalSafetyCode() throws -> String? {
        guard let raw = ProcessInfo.processInfo.environment["VETTID_STAGING_SAFETY_CODE"], !raw.isEmpty else { return nil }
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        let allowed = raw.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == " " || $0 == "-" }
        guard allowed, digits.count == 6 else { throw ConnectInputError.safetyCodeNotSixDigits }
        return digits
    }

    enum ConnectInputError: Error, CustomStringConvertible {
        case linkNotHttps
        case safetyCodeNotSixDigits

        var description: String {
            switch self {
            case .linkNotHttps: "VETTID_STAGING_LINK is not an https link"
            case .safetyCodeNotSixDigits: "VETTID_STAGING_SAFETY_CODE is not six digits"
            }
        }
    }
}
