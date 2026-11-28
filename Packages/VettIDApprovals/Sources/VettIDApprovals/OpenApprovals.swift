import Foundation
import VettIDData

/// What the approvals indicator and the drawer's Approvals badge show (ANDROID-PLAN §4 "The approvals indicator", D9;
/// IOS-PLAN §4.12, ID19): [count] open approvals, and [critical] while one of them is time-critical. One source for both.
/// Mirrors vettid-android `OpenApprovals`.
public struct OpenApprovals: Equatable, Sendable {
    public var count: Int
    public var critical: CriticalApproval?

    public init(count: Int = 0, critical: CriticalApproval? = nil) {
        self.count = count
        self.critical = critical
    }
}

/// The time-critical state: [deadline] is the soonest time-critical entry's `exp` (nil while none of them has one: the clock
/// alone), [label] that entry's name for the description (nil when it names none), and [urgent] whether any time-critical
/// entry is other than a sign-in (urgency colours; sign-ins alone are neutral). Mirrors vettid-android `CriticalApproval`.
public struct CriticalApproval: Equatable, Sendable {
    public var deadline: Date?
    public var urgent: Bool
    public var label: String?

    public init(deadline: Date?, urgent: Bool, label: String?) {
        self.deadline = deadline
        self.urgent = urgent
        self.label = label
    }
}

/// The rules of ANDROID-PLAN §4 "The approvals indicator" 1, 3 and 5, pure. Mirrors vettid-android `OpenApprovalRules`.
public enum OpenApprovalRules {
    /// An entry with a deadline becomes time-critical in its last 2 minutes (`APPROVAL_URGENT_SECONDS`).
    public static let approvalUrgentSeconds: TimeInterval = 120

    /// An open approval at [now] (1): an entry waiting for this member's decision (``PendingApproval/needsDecision``: a
    /// connection request waiting for the handshake or for the other side is not) whose deadline has not passed (`exp`; an
    /// entry with none counts until it is decided). Votes and notices are not Approvals entries.
    public static func counts(_ a: PendingApproval, now: Date) -> Bool {
        a.needsDecision && (a.exp.map { now < $0 } ?? true)
    }

    /// Time-critical from arrival (5a): a `connection.authenticate` challenge of any purpose, a `device.session.pending`
    /// request and an `approval.pending` request.
    public static func criticalFromArrival(_ a: PendingApproval) -> Bool {
        switch a {
        case .authentication: true
        case .device(let d): d.type == "device.session.pending" || DeviceAsks.isHeld(d)
        default: false
        }
    }

    /// Time-critical at [now] (5): from arrival, or in the last ``approvalUrgentSeconds`` before the entry's deadline.
    public static func timeCritical(_ a: PendingApproval, now: Date) -> Bool {
        criticalFromArrival(a) || (a.exp.map { now.addingTimeInterval(approvalUrgentSeconds) >= $0 } ?? false)
    }

    /// A sign-in challenge (`purpose: "signin"`) gets the neutral countdown, every other time-critical entry the urgent one.
    public static func signIn(_ a: PendingApproval) -> Bool {
        if case .authentication(let x) = a { return x.purpose == .signin }
        return false
    }

    /// [list] at [now]; [connectionName] gives a connection's shown name by its id (nil when it has none).
    public static func of(_ list: [PendingApproval], now: Date, connectionName: (String) -> String? = { _ in nil }) -> OpenApprovals {
        let open = list.filter { counts($0, now: now) }
        // One entry per row of the Approvals list: a connection's asks within 10 minutes of the first are one batch.
        let count = AskBatches.group(open).count
        let critical = open.filter { timeCritical($0, now: now) }
        if critical.isEmpty { return OpenApprovals(count: count) }
        let soonest = critical.filter { $0.exp != nil }.min { ($0.exp ?? .distantFuture) < ($1.exp ?? .distantFuture) }
        return OpenApprovals(
            count: count,
            critical: CriticalApproval(
                deadline: soonest?.exp, urgent: critical.contains { !signIn($0) }, label: soonest.flatMap { label($0, connectionName) }
            )
        )
    }

    /// The instants at which ``of(_:now:connectionName:)`` can change by time alone: each deadline, and the start of its last
    /// 2 minutes.
    public static func changesAt(_ list: [PendingApproval]) -> [Date] {
        list.filter(\.needsDecision).compactMap(\.exp).flatMap { [$0.addingTimeInterval(-approvalUrgentSeconds), $0] }
    }

    /// The name an entry carries: its connection's, a connection request's own, else its device's; nil when it names none.
    static func label(_ a: PendingApproval, _ connectionName: (String) -> String?) -> String? {
        let own: String? = switch a {
        case .connection(let r): r.name
        case .device(let d): d.deviceName
        default: nil
        }
        let named = a.connectionID.flatMap(connectionName)
        return AccountNames.cleaned(named) ?? AccountNames.cleaned(own)
    }
}

/// What time it is for deadlines (vettid-android `deadlineClock`): [emit] gets now, then again at each of [points] still to
/// come (one sleep to the next, never a polling loop); it returns when none is left or the task is cancelled. A sleep does
/// not run while the phone sleeps, so the caller starts it again when the app comes back to the front.
public struct DeadlineClock: Sendable {
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    public func run(_ points: [Date], emit: @MainActor (Date) -> Void) async {
        await emit(now())
        for at in Set(points).sorted() {
            let wait = at.timeIntervalSince(now())
            if wait < 0 { continue }
            if wait > 0 {
                do { try await sleep(wait) } catch { return }
            }
            if Task.isCancelled { return }
            // The sleep ended at the point: report at least that instant.
            await emit(max(now(), at))
        }
    }
}
