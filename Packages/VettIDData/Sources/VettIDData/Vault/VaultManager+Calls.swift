import Foundation
import VettIDVault

// What the calls (`VettIDCalls`) use of the vault manager: the typed client of the open vault, and whether the release-update
// screen covers the app. Nothing else of the manager is opened to them (vettid-android `CallsModule.ManagerVault`).
extension VaultManager {
    /// The vault client for the calls: the session of the vault open on this phone (a call is placed, answered and heard only
    /// then), refused (`lock_pending`) while a lock is pending. With the vault not open it throws `session_dropped`, and the calls'
    /// event listening asks again after a pause.
    public func callApi() throws -> VaultApi {
        guard phase == .unlocked, let s = session else { throw VaultFailure(.other, code: "session_dropped") }
        return try openApi(s)
    }

    /// True while the release update's progress or outcome is shown over the app: no screen could answer a call, so none rings.
    public var releaseUpdateShowing: Bool { releaseUpdate.progress != nil }
}
