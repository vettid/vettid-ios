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

    /// A `call.end` through the session in use, also while the member's lock is pending and the phone is already locked: the hang-up
    /// of the call the lock ends goes before the vault is told to lock, so that the other member is not left listening to silence
    /// (``LockTimeUse/callEnd``; vettid-android `sendCallEnd`). Nothing else is sent this way, the client is not handed out, and
    /// there is no check of the phase: only a phone with no session at all refuses (`session_dropped`).
    public func sendCallEnd(callId: String, reason: String) async throws {
        guard let s = session, lockGuard.admits(.callEnd) else { throw VaultFailure(.other, code: "session_dropped") }
        try await s.api.callEnd(callId, reason: reason)
    }

    /// True while the release update's progress or outcome is shown over the app: no screen could answer a call, so none rings.
    public var releaseUpdateShowing: Bool { releaseUpdate.progress != nil }
}
