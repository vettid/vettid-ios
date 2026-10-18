import Foundation

/// One wipe of this phone (``VaultManager``'s), in an order that fails secure:
///
/// 1. the account record's guard shuts (``AccountRecord/beginWipe()``): from here no session opens;
/// 2. [abandonLock], then [detach]: the lock keeper is abandoned and the session, its observers and the relay collection
///    stop;
/// 3. [mark]: the wipe's marker, which makes a later start finish it, tried [attempts] times;
/// 4. [erase]: everything else; true when nothing is left.
///
/// Whatever happens, both run again (nothing opened meanwhile outlives the wipe), the guard ends
/// (``AccountRecord/endWipe(complete:)``: open on the fresh record only after a complete erase, shut otherwise) and
/// [onEnd] hears the phase to show: ``AppPhase/signedOut`` only after a complete erase; otherwise ``failedPhase``, which
/// says that this phone was not erased and offers to try again. Mirrors vettid-android `WipeRun`.
@MainActor
struct WipeRun {
    nonisolated static let markAttempts = 3
    nonisolated static let markRetry: Duration = .milliseconds(500)
    /// A wipe that did not finish (or never started): said, with "Try again", never as a clean welcome screen.
    nonisolated static let failedPhase = AppPhase.unreachable(.eraseFailed, longUnreachable: false)
    /// The code of an operation refused while a wipe is unfinished.
    nonisolated static let codeWipePending = "wipe_pending"

    let record: AccountRecord
    let abandonLock: @MainActor () -> Void
    let detach: @MainActor () async -> Void
    let mark: @MainActor () throws -> Void
    let erase: @MainActor () async -> Bool
    let onEnd: @MainActor (AppPhase) -> Void
    var attempts = WipeRun.markAttempts
    var sleep: LockSleep = realLockSleep

    func run() async {
        record.beginWipe()
        var complete = false
        await detachAll()
        if await marked() { complete = await erase() }
        await detachAll()
        record.endWipe(complete: complete)
        onEnd(complete ? .signedOut : Self.failedPhase)
    }

    private func detachAll() async {
        abandonLock()
        await detach()
    }

    /// The marker, tried again after a failure: one that cannot be written, for any reason, is tried [attempts] times.
    private func marked() async -> Bool {
        for i in 0..<attempts {
            do {
                try mark()
                return true
            } catch {
                if i < attempts - 1 { try? await sleep(Self.markRetry) }
            }
        }
        return false
    }
}
