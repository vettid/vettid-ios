import Foundation

extension OwnerCheckManager {
    /// What is kept on the phone. `waiting` nil: the vault has not said what is waiting (never zero for unknown);
    /// `heldTs`: the `ts` of the `vault.held` the counts came from.
    struct Saved: Codable {
        var state: OwnerCheckState
        var deadline: Date?
        var interval: Int64
        var failures: Int
        var hold: Bool
        var holdOffUntil: Date?
        var waiting: WaitingCounts?
        var heldTs: Date?
        var presenceUnrecorded: Bool
        var presenceCheckAt: Date?
        /// The deadline's time scale; absent in a file written before it (1).
        var timeScale: UInt64?
        /// (Release L) ``OwnerCheckView/idleLockAt``; the vault locked itself and how long past the deadline; the lowest
        /// idle-lock value since the last check; the value in force as read before the deadline; locked on this phone.
        var idleLockAt: Date?
        var idleLocked: Bool?
        var idleAfter: Int64?
        var idleInForce: Int64?
        var idleAfterKnown: Int64?
        var lockedHere: Bool?
        /// Only the idle-lock flags were kept: no view of the check had been read.
        var viewless: Bool?

        init(view v: OwnerCheckView, heldTs: Date?, presenceUnrecorded: Bool, presenceCheckAt: Date?) {
            state = v.state
            deadline = v.deadline
            interval = v.intervalSeconds
            failures = v.failures
            hold = v.hold
            holdOffUntil = v.holdOffUntil
            waiting = v.waiting
            self.heldTs = heldTs
            self.presenceUnrecorded = presenceUnrecorded
            self.presenceCheckAt = presenceCheckAt
            timeScale = v.timeScale
            idleLockAt = v.idleLockAt
        }

        var view: OwnerCheckView {
            OwnerCheckView(
                state: state, deadline: deadline, intervalSeconds: interval, failures: failures, hold: hold,
                holdOffUntil: holdOffUntil, waiting: waiting, timeScale: max(timeScale ?? 1, 1),
                idleLockAt: idleLockAt
            )
        }
    }
}
