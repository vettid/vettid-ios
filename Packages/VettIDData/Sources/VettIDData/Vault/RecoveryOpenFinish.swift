import Foundation

/// (Release R) The end of a recovery the vault answered `ok`, after the member has read that text
/// (``VaultManager/finishRecoveryOpen()``). A recovered phone is a new install (`setupComplete` false), so the vault's
/// unlock ends in ``SetupStage/finishing``; the `ok` text is that phone's last setup screen, so setup is finished here too.
/// Kept apart from ``VaultManager`` so that its rules can be tested (vettid-android `RecoveryOpenFinish`):
///
/// - a lock asked for since the open began, or pending now, wins: the phase is ``AppPhase/locked`` (or, after a wipe,
///   whatever the wipe said), never the open app, and the caller is told (``MoveCodes/lockPending``);
/// - the open app only through ``Ports/finishSetup()`` (its gate: only from ``SetupStage/finishing``, never over a pending
///   lock or a running "Finish the move");
/// - an open that did not end in the open app fails (``MoveCodes/notOpened``), so that the screen says so and stays,
///   rather than staying silently.
enum RecoveryOpenFinish {
    /// What stopped this phone from opening since the open began.
    enum Overtaken: Equatable, Sendable {
        /// Nothing.
        case no
        /// A lock is pending: this phone is locked whatever the vault says.
        case lockPending
        /// A lock (already confirmed) or a wipe since the open began: the phase it published stands.
        case other
    }

    @MainActor
    protocol Ports {
        /// Checked before each step: a lock or a wipe since the open began, or a lock pending now.
        func overtaken() -> Overtaken

        /// The phase after the vault's unlock: ``AppPhase/unlocked``, or ``SetupStage/finishing`` on a phone whose setup is not
        /// complete.
        func afterUnlocked() async throws -> AppPhase

        func publish(_ phase: AppPhase)

        /// Leaves onboarding for the open app under its gate; false when the gate refused.
        func finishSetup() async throws -> Bool
    }

    /// Ends in the open app, or throws a ``VaultFailure`` (the phase left ``AppPhase/locked``, or as a lock or a wipe set it).
    @MainActor
    static func run(_ ports: some Ports) async throws {
        try stopIfOvertaken(ports)
        let phase = try await ports.afterUnlocked()
        // Before the phase is written: a lock asked for while it was computed is the newer wish.
        try stopIfOvertaken(ports)
        ports.publish(phase)
        switch phase {
        case .unlocked: return
        case .setup(.finishing): if try await ports.finishSetup() { return }
        default: break
        }
        // The gate refused (a lock asked for meanwhile, "Finish the move"), or the vault's unlock did not end where an `ok`
        // leaves it: never the open app, and the screen says so.
        try stopIfOvertaken(ports)
        throw VaultFailure(.other, code: MoveCodes.notOpened)
    }

    @MainActor
    private static func stopIfOvertaken(_ ports: some Ports) throws {
        switch ports.overtaken() {
        case .no: return
        case .lockPending:
            ports.publish(.locked)
            throw VaultFailure(.noResponse, code: MoveCodes.lockPending)
        case .other: throw VaultFailure(.other, code: MoveCodes.notOpened)
        }
    }
}
