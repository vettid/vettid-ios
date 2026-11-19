import XCTest

/// The release gate's update (testStagingReleaseGate): Rule 3's one older-release case. A vault on the previous release
/// that moves to the current one through "Approve and update" keeps its state.
extension StagingTests {
    /// "Continue" after the update was done: the open app (through the owner check if due); false after the failure. The
    /// opening's own check of the new release may still show "Checking your vault's software" first: only an offer there
    /// says the vault is still behind.
    @MainActor
    func openedAfterUpdate(_ app: XCUIApplication, pin: String, password: String) -> Bool {
        var opened = waitForAny(app, ["app_shell", "owner_check", "release_required"], timeout: Self.network)
        if opened == "release_required" {
            opened = waitForAny(app, ["app_shell", "owner_check", "release_offer"], timeout: Self.network)
        }
        switch opened {
        case "owner_check":
            return ownerCheck(app, pin: pin, password: password)
        case "app_shell":
            return true
        case "release_offer":
            fail(app, "The gate still offers an update after it was done.")
        case "release_required":
            // Fail-closed: a manifest that could not be read keeps the check, so a transient error fails here too.
            fail(app, "The new release's check did not end (a manifest read that failed keeps it).")
        default:
            fail(app, "The app did not open on the new release.")
        }
        return false
    }

    /// After the update, the app opened on the same vault: with VETTID_STAGING_PEER_NAME, Connections and Messages still show
    /// that connection and its conversation; with VETTID_STAGING_ITEM_NAME, Vault still shows that item. Each optional input
    /// left unset is noted, not failed (the script says so too).
    @MainActor
    func keptAfterUpdate(_ app: XCUIApplication) {
        let env = ProcessInfo.processInfo.environment
        if let peer = Self.firstPeerName(env["VETTID_STAGING_PEER_NAME"]) {
            guard openConnections(app) else { return }
            if !waitUntil(timeout: Self.network, { row(app, prefix: "connection_", named: peer, excluding: []) != nil }) {
                return fail(app, "Connections no longer shows VETTID_STAGING_PEER_NAME after the update.")
            }
            guard openFromDrawer(app, item: "drawer_messages", screen: "messages_screen", what: "Messages") else { return }
            let conversation = waitUntil(timeout: Self.network) {
                row(app, prefix: "conversation_", named: peer, excluding: Self.conversationParts) != nil
            }
            if !conversation { return fail(app, "Messages no longer shows the conversation with VETTID_STAGING_PEER_NAME.") }
            snap(app, "9-kept-connection")
        } else {
            XCTContext.runActivity(named: "VETTID_STAGING_PEER_NAME not set: connections and conversations not checked") { _ in }
        }
        if let item = env["VETTID_STAGING_ITEM_NAME"], !item.isEmpty {
            guard openFromDrawer(app, item: "drawer_items", screen: "items", what: "Vault") else { return }
            if !waitUntil(timeout: Self.network, { row(app, prefix: "items_row_", named: item, excluding: []) != nil }) {
                return fail(app, "Vault no longer shows VETTID_STAGING_ITEM_NAME after the update.")
            }
            snap(app, "9-kept-item")
        } else {
            XCTContext.runActivity(named: "VETTID_STAGING_ITEM_NAME not set: items not checked") { _ in }
        }
    }

    /// The first connection's name of VETTID_STAGING_PEER_NAME: a plain name, or the first entry of a list
    /// ("Name=label;Name=label"), trimmed, as the script's redactor reads it; nil when unset.
    static func firstPeerName(_ value: String?) -> String? {
        guard let first = value?.split(separator: ";").first else { return nil }
        let name = first.split(separator: "=", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? nil : name
    }
}
